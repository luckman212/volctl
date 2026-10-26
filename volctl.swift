import CoreAudio
import Foundation

let programVersion = "1.2.0"

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum Action {
    case list
    case get(deviceID: AudioDeviceID, type: String?)
    case set(deviceID: AudioDeviceID, level: Float32, type: String?)
    case mute(deviceID: AudioDeviceID, state: String?, type: String?)
    case invalid(String)
}

var isDebugEnabled: Bool = {
    let debugValue = ProcessInfo.processInfo.environment["DEBUG"]?.lowercased()
    return ["1", "true", "yes"].contains(debugValue)
}()

var isQuietEnabled = false

func writeMessage(_ message: String, to handle: FileHandle, terminator: String = "\n") {
    guard !isQuietEnabled else { return }
    if let data = (message + terminator).data(using: .utf8) {
        handle.write(data)
    }
}

func log(_ message: String, isDebug: Bool = false, isError: Bool = false, terminator: String = "\n") {
    if isDebug && !isDebugEnabled { return }
    let output = isError ? FileHandle.standardError : FileHandle.standardOutput
    writeMessage(message, to: output, terminator: terminator)
}

func parseTypeArgument(_ type: String) -> Bool? {
    switch type.lowercased() {
    case "input":
        return true
    case "output":
        return false
    default:
        return nil
    }
}

func resolveDeviceDirection(
    deviceType: (isInput: Bool, isOutput: Bool),
    type: String?
) -> Bool? {
    guard let type = type else {
        return !deviceType.isOutput && deviceType.isInput
    }

    guard let isInput = parseTypeArgument(type) else {
        log("Invalid type. Specify 'input' or 'output'.", isError: true)
        return nil
    }

    if isInput && !deviceType.isInput {
        log("This device does not support input", isError: true)
        return nil
    }

    if !isInput && !deviceType.isOutput {
        log("This device does not support output", isError: true)
        return nil
    }

    return isInput
}

func fourCharCode(_ string: String) -> AudioObjectPropertySelector {
    guard string.count == 4 else { return 0 }
    return string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

func getDeviceName(deviceID: AudioDeviceID) -> String? {
    var propertySize = UInt32(MemoryLayout<CFString?>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var name: CFString? = nil
    let status = withUnsafeMutablePointer(to: &name) { namePointer in
        namePointer.withMemoryRebound(to: UInt8.self, capacity: Int(propertySize)) { rawPointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, rawPointer)
        }
    }

    guard status == noErr else {
        log("Error retrieving name for device \(deviceID)", isError: true)
        return nil
    }

    return name as String?
}

func getDeviceType(deviceID: AudioDeviceID) -> (isInput: Bool, isOutput: Bool) {
    func hasStreams(scope: AudioObjectPropertyScope) -> Bool {
        getChannelCount(deviceID: deviceID, scope: scope) > 0
    }
    return (
        hasStreams(scope: kAudioDevicePropertyScopeInput),
        hasStreams(scope: kAudioDevicePropertyScopeOutput)
    )
}

func getChannelCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    var propertySize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize) == noErr,
          propertySize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
        return 0
    }

    let rawPointer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(propertySize),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawPointer.deallocate() }

    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, rawPointer) == noErr else {
        return 0
    }

    let bufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
    let audioBuffers = UnsafeMutableAudioBufferListPointer(bufferList)

    return audioBuffers.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func getPropertyValue(
    deviceID: AudioDeviceID,
    scope: AudioObjectPropertyScope,
    selectors: [(AudioObjectPropertySelector, String)]
) -> Float32? {
    for (selector, description) in selectors {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(deviceID, &address) {
            var value: Float32 = 0.0
            var size = UInt32(MemoryLayout.size(ofValue: value))
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
                log("Successfully retrieved \(description): \(value)", isDebug: true)
                return value
            }
        }
    }

    return nil
}

func getVolumeForChannel(deviceID: AudioDeviceID, channel: UInt32, scope: AudioObjectPropertyScope) -> Float32? {
    let volumeSelectors: [(AudioObjectPropertySelector, String)] = [
        (kAudioDevicePropertyVolumeScalar, "Volume Scalar"),
        (kAudioDevicePropertyVolumeDecibels, "Volume Decibels"),
        (fourCharCode("gain"), "Gain")
    ]

    for (selector, description) in volumeSelectors {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: channel
        )

        if AudioObjectHasProperty(deviceID, &address) {
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)

            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
                log("Successfully got \(description) for channel \(channel): \(value)", isDebug: true)
                return value
            }
        }
    }

    return nil
}

func getVolumeWithFallback(deviceID: AudioDeviceID, isInput: Bool) -> [Float32]? {
    let scope: AudioObjectPropertyScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput

    if let mainVolume = getPropertyValue(
        deviceID: deviceID,
        scope: scope,
        selectors: [
            (kAudioDevicePropertyVolumeScalar, "Volume Scalar"),
            (kAudioDevicePropertyVolumeDecibels, "Volume Decibels")
        ]
    ) {
        return [mainVolume]
    }

    if let mainGain = getPropertyValue(
        deviceID: deviceID,
        scope: scope,
        selectors: [
            (fourCharCode("gain"), "Gain")
        ]
    ) {
        return [mainGain]
    }

    let channelCount = getChannelCount(deviceID: deviceID, scope: scope)
    guard channelCount > 0 else {
        return nil
    }

    let volumes = (1...UInt32(channelCount)).compactMap {
        getVolumeForChannel(deviceID: deviceID, channel: $0, scope: scope)
    }

    return volumes.isEmpty ? nil : volumes
}

func setChannelVolume(deviceID: AudioDeviceID, volumes: [Float32], scope: AudioObjectPropertyScope) -> Bool {
    var foundSettableChannel = false
    var allSettableChannelsSucceeded = true

    for (index, volume) in volumes.enumerated() {
        let channel = UInt32(index + 1)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: channel
        )

        var isSettable: DarwinBoolean = false
        guard AudioObjectHasProperty(deviceID, &address),
              AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else {
            log("Volume property not available or not settable for channel \(channel)", isError: true)
            continue
        }

        foundSettableChannel = true

        var value = volume
        if AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout.size(ofValue: value)),
            &value
        ) == noErr {
            log("Successfully set volume for channel \(channel) to \(volume)", isDebug: true)
        } else {
            log("Failed to set volume for channel \(channel)", isError: true)
            allSettableChannelsSucceeded = false
        }
    }

    return foundSettableChannel && allSettableChannelsSucceeded
}

func getMuteState(deviceID: AudioDeviceID, isInput: Bool) -> Bool? {
    let scope: AudioObjectPropertyScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceID, &address) {
        var muteState: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &muteState
        )

        if status == noErr {
            return muteState != 0
        } else {
            log("Failed to get mute state: \(status)", isError: true)
        }
    } else {
        log("Device does not support mute property", isError: true)
    }

    return nil
}

func setMuteState(deviceID: AudioDeviceID, muted: Bool, isInput: Bool) -> Bool {
    let scope: AudioObjectPropertyScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceID, &address) {
        var isSettable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)

        if settableStatus == noErr && isSettable.boolValue {
            var muteState: UInt32 = muted ? 1 : 0
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &muteState
            )

            if status == noErr {
                log("Successfully \(muted ? "muted" : "unmuted") the device", isDebug: true)
                return true
            } else {
                log("Failed to set mute state: \(status)", isError: true)
            }
        } else {
            log("Mute property is not settable", isError: true)
        }
    } else {
        log("Device does not support mute property", isError: true)
    }

    return false
}

func handleMuteCommand(deviceID: AudioDeviceID, state: String?, type: String?) -> Bool {
    let deviceType = getDeviceType(deviceID: deviceID)
    log("Device capabilities - Input: \(deviceType.isInput), Output: \(deviceType.isOutput)", isDebug: true)

    guard let isInput = resolveDeviceDirection(deviceType: deviceType, type: type) else {
        return false
    }

    guard let currentMuteState = getMuteState(deviceID: deviceID, isInput: isInput) else {
        log("Unable to get current mute state", isError: true)
        return false
    }

    let targetMuteState: Bool
    if let state = state?.lowercased() {
        switch state {
        case "on":
            targetMuteState = true
        case "off":
            targetMuteState = false
        case "toggle":
            targetMuteState = !currentMuteState
        default:
            log("Invalid mute state. Use 'on', 'off', or 'toggle'", isError: true)
            return false
        }
    } else {
        targetMuteState = !currentMuteState
    }

    if targetMuteState != currentMuteState {
        return setMuteState(deviceID: deviceID, muted: targetMuteState, isInput: isInput)
    } else {
        log("Device is already \(targetMuteState ? "muted" : "unmuted")", isDebug: true)
        return true
    }
}

func getVolume(deviceID: AudioDeviceID, type: String?) -> Bool {
    let deviceType = getDeviceType(deviceID: deviceID)

    guard let isInput = resolveDeviceDirection(deviceType: deviceType, type: type) else {
        return false
    }

    guard let volumes = getVolumeWithFallback(deviceID: deviceID, isInput: isInput) else {
        log("No volume available for this device.", isError: true)
        return false
    }

    var seen = Set<String>()
    let uniqueVolumes = volumes.filter { vol in
        let key = String(format: "%.4f", Double(vol))
        return seen.insert(key).inserted
    }

    let volumeStrings = uniqueVolumes.map { String(format: "%.4f", Double($0)) }
    log(volumeStrings.joined(separator: "\t"))
    return true
}

func setVolume(deviceID: AudioDeviceID, level: Float32, type: String?) -> Bool {
    let deviceType = getDeviceType(deviceID: deviceID)

    guard let isInput = resolveDeviceDirection(deviceType: deviceType, type: type) else {
        return false
    }

    let scope: AudioObjectPropertyScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    let channelCount = getChannelCount(deviceID: deviceID, scope: scope)

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectHasProperty(deviceID, &address) {
        var isSettable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr, isSettable.boolValue {
            var newVolume = level
            if AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout.size(ofValue: newVolume)),
                &newVolume
            ) == noErr {
                log("Successfully set main volume to \(level)", isDebug: true)
                return true
            }
        }
    }

    if channelCount > 0 {
        let volumes = [Float32](repeating: level, count: channelCount)
        if setChannelVolume(deviceID: deviceID, volumes: volumes, scope: scope) {
            log("Successfully set volume for available channels to \(level)", isDebug: true)
            return true
        } else {
            log("Failed to set volume", isError: true)
        }
    } else {
        log("No channels available to set volume on.", isError: true)
    }

    return false
}

func getDefaultDevice(isInput: Bool) -> AudioDeviceID? {
    let direction = isInput ? "input" : "output"
    var address = AudioObjectPropertyAddress(
        mSelector: isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioDeviceID = kAudioObjectUnknown
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &propertySize,
        &deviceID
    )

    guard status == noErr else {
        log("Error retrieving default \(direction) device: \(status)", isError: true)
        return nil
    }

    guard propertySize == UInt32(MemoryLayout<AudioDeviceID>.size) else {
        log("Invalid data size for default \(direction) device: \(propertySize)", isError: true)
        return nil
    }

    guard deviceID != kAudioObjectUnknown else {
        log("No default \(direction) device is available.", isError: true)
        return nil
    }

    log("Resolved default \(direction) device to ID: \(deviceID)", isDebug: true)
    return deviceID
}

func resolveDevice(_ arg: String, type: String? = nil) -> (id: AudioDeviceID, type: String?)? {
    let requestedIsInput = type.flatMap(parseTypeArgument)

    guard type == nil || requestedIsInput != nil else {
        log("Invalid type. Specify 'input' or 'output'.", isError: true)
        return nil
    }

    if let id = UInt32(arg) {
        if id == kAudioObjectUnknown {
            let isInput = requestedIsInput ?? false

            guard let deviceID = getDefaultDevice(isInput: isInput) else {
                return nil
            }

            return (deviceID, isInput ? "input" : "output")
        }

        guard getDeviceName(deviceID: id) != nil else {
            return nil
        }
        log("Selected device ID: \(id)", isDebug: true)
        return (id, type)
    }

    let lowerArg = arg.lowercased()
    let devices = getAllDevices()

    for device in devices {
        guard device.name.lowercased().contains(lowerArg) else {
            continue
        }

        if let requestedIsInput = requestedIsInput {
            if requestedIsInput && !device.isInput {
                continue
            }
            if !requestedIsInput && !device.isOutput {
                continue
            }
        }

        log("Resolved '\(arg)' => \(device.name) (id: \(device.id))", isDebug: true)
        return (device.id, type)
    }

    return nil
}

func getAllDevices() -> [(id: AudioDeviceID, name: String, isInput: Bool, isOutput: Bool)] {
    var propertySize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize) == noErr else {
        return []
    }

    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: AudioDeviceID(), count: deviceCount)

    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &propertySize,
        &deviceIDs
    ) == noErr else {
        return []
    }

    var results: [(id: AudioDeviceID, name: String, isInput: Bool, isOutput: Bool)] = []
    for deviceID in deviceIDs {
        let name = getDeviceName(deviceID: deviceID) ?? "Unknown"
        let deviceType = getDeviceType(deviceID: deviceID)
        results.append((id: deviceID, name: name, isInput: deviceType.isInput, isOutput: deviceType.isOutput))
    }

    return results
}

func parseGlobalOptions() -> [String] {
    var remaining: [String] = []
    for arg in CommandLine.arguments.dropFirst() {
        switch arg {
        case "-v", "--version":
            log(programVersion)
            exit(EXIT_SUCCESS)
        case "-q", "--quiet":
            isQuietEnabled = true
        default:
            remaining.append(arg)
        }
    }
    return remaining
}

func parseCommandLine(arguments: [String]) -> Action {
    let action = arguments[safe: 0]?.lowercased() ?? ""

    if ["-h", "--help"].contains(action) || action.isEmpty {
        printUsage()
        exit(EXIT_SUCCESS)
    }

    switch action {
    case "list":
        return .list

    case "get":
        let type = arguments[safe: 2]
        guard let arg = arguments[safe: 1],
              let device = resolveDevice(arg, type: type) else {
            return .invalid("Usage: volctl [-q] get <device_id|device_name> [type: input|output]")
        }
        return .get(deviceID: device.id, type: device.type)

    case "set":
        let type = arguments[safe: 3]
        guard let arg = arguments[safe: 1],
              let levelStr = arguments[safe: 2],
              let level = Float32(levelStr),
              level >= 0, level <= 1,
              let device = resolveDevice(arg, type: type) else {
            return .invalid("Usage: volctl [-q] set <device_id|device_name> <level (0.0-1.0)> [type: input|output]")
        }

        return .set(deviceID: device.id, level: level, type: device.type)

    case "mute":
        let stateOrType = arguments[safe: 2]
        let state: String?
        let type: String?

        if let value = stateOrType, parseTypeArgument(value) != nil {
            state = nil
            type = value
        } else {
            state = stateOrType
            type = arguments[safe: 3]
        }

        guard let arg = arguments[safe: 1],
              let device = resolveDevice(arg, type: type) else {
            return .invalid("Usage: volctl [-q] mute <device_id|device_name> [on|off|toggle] [type: input|output]")
        }

        return .mute(deviceID: device.id, state: state, type: device.type)

    default:
        return .invalid("Invalid action. Use 'list', 'get', 'set', or 'mute'.")
    }
}

func listDevices() {
    var devices = getAllDevices()
    devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    for device in devices {
        let typeDescription: String
        if device.isInput && device.isOutput {
            typeDescription = "In/Out"
        } else if device.isInput {
            typeDescription = "Input"
        } else if device.isOutput {
            typeDescription = "Output"
        } else {
            typeDescription = "Unknown"
        }
        log("\(device.id)\t\(typeDescription)\t\(device.name)")
    }
}

func printUsage() {
    log("""
    Get or set volume levels or mute state for macOS audio devices
    Usage: volctl [-q] <command> [args]

    Global options:
        -q, --quiet                    Suppress all stdout/stderr output
        -v, --version                  Show version

    Commands:
        list                           List all audio devices (tab-separated)
        get <device> [type]            Get volume level for a device
        set <device> <level> [type]    Set volume level for a device (0.0-1.0)
        mute <device> [state] [type]   Control mute state; state is on|off|toggle

    Notes:
        - <device> can be an ID number or a string (partial match is ok)
        - Device ID 0 selects the current default device
          (output unless [type] is input; not the separate system-sound output)
        - Selecting a default device does not change the macOS defaults
        - When using a string to select device, the first matching device is used
        - [type] is optional: input | output
          (if supplied, name matching is limited to devices supporting that direction)
        - get, set, and mute return 0 on success or 1 on failure
          (quiet mode suppresses messages without changing the exit status)
    """)
}

let positionalArgs = parseGlobalOptions()

let action = parseCommandLine(arguments: positionalArgs)
let succeeded: Bool

switch action {
case .list:
    listDevices()
    succeeded = true

case .get(let deviceID, let type):
    succeeded = getVolume(deviceID: deviceID, type: type)

case .set(let deviceID, let level, let type):
    succeeded = setVolume(deviceID: deviceID, level: level, type: type)

case .mute(let deviceID, let state, let type):
    succeeded = handleMuteCommand(deviceID: deviceID, state: state, type: type)

case .invalid(let error):
    log(error, isError: true)
    succeeded = false
}

exit(succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
