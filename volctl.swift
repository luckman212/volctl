import CoreAudio
import Foundation

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
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
    if ["1", "true", "yes"].contains(debugValue) { return true }
    return false
}()

func log(_ message: String, isDebug: Bool = false, isError: Bool = false, terminator: String = "\n") {
    if isDebug && !isDebugEnabled { return }
    let output = isError ? FileHandle.standardError : FileHandle.standardOutput
    if let data = (message + terminator).data(using: .utf8) {
        output.write(data)
    }
}

func parseTypeArgument(_ type: String) -> Bool? {
    switch type.lowercased() {
    case "input": return true
    case "output": return false
    default: return nil
    }
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
        let channelCount = getChannelCount(deviceID: deviceID, scope: scope)
        return channelCount > 0
    }
    return (hasStreams(scope: kAudioDevicePropertyScopeInput), hasStreams(scope: kAudioDevicePropertyScopeOutput))
}

func getChannelCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var propertySize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize) == noErr,
          propertySize > 0 else {
        return 0
    }

    let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(propertySize), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { bufferListPointer.deallocate() }

    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferListPointer) == noErr else {
        return 0
    }

    let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
    
    var totalChannels = 0
    let bufferCount = Int(audioBufferList.pointee.mNumberBuffers)

    if bufferCount == 1 {
        totalChannels = Int(audioBufferList.pointee.mBuffers.mNumberChannels)
    } else {
        let buffersPtr = withUnsafePointer(to: &audioBufferList.pointee.mBuffers) { ptr in
            UnsafeBufferPointer(start: ptr, count: bufferCount)
        }
        
        for i in 0..<bufferCount {
            totalChannels += Int(buffersPtr[i].mNumberChannels)
        }
    }
    
    return totalChannels
}

func getPropertyValue(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, selectors: [(AudioObjectPropertySelector, String)]) -> Float32? {
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
        (fourCharCode("gain"), "Gain"),
        (fourCharCode("gain"), "Gain Scalar")
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
    
    if let mainVolume: Float32 = getPropertyValue(deviceID: deviceID, scope: scope, selectors: [
        (kAudioDevicePropertyVolumeScalar, "Volume Scalar"),
        (kAudioDevicePropertyVolumeDecibels, "Volume Decibels")
    ]) {
        return [mainVolume]
    }
    
    if let mainGain: Float32 = getPropertyValue(deviceID: deviceID, scope: scope, selectors: [
        (fourCharCode("gain"), "Gain"),
        (fourCharCode("gain"), "Gain Scalar")
    ]) {
        return [mainGain]
    }
    
    let channelCount = getChannelCount(deviceID: deviceID, scope: scope)
    guard channelCount > 0 else {
        return nil
    }
    
    var volumes: [Float32] = []
    for channel in 1...UInt32(channelCount) {
        if let vol = getVolumeForChannel(deviceID: deviceID, channel: channel, scope: scope) {
            volumes.append(vol)
        } else {
            volumes.append(-1.0)
        }
    }
    
    let validVolumes = volumes.filter { $0 >= 0.0 && $0 <= 1.0 }
    return validVolumes.isEmpty ? nil : volumes
}

func setChannelVolume(deviceID: AudioDeviceID, volumes: [Float32], scope: AudioObjectPropertyScope) -> Bool {
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
        
        var value = volume
        if AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value) == noErr {
            log("Successfully set volume for channel \(channel) to \(volume)", isDebug: true)
        } else {
            log("Failed to set volume for channel \(channel)", isError: true)
            return false
        }
    }
    return true
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
                print("Successfully \(muted ? "muted" : "unmuted") the device")
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
    
    let isInput: Bool
    if let type = type {
        guard let inputType = parseTypeArgument(type) else {
            log("Invalid type. Specify 'input' or 'output'.", isError: true)
            return false
        }
        isInput = inputType
        
        if isInput && !deviceType.isInput {
            log("This device does not support input", isError: true)
            return false
        } else if !isInput && !deviceType.isOutput {
            log("This device does not support output", isError: true)
            return false
        }
    } else {
        isInput = !deviceType.isOutput && deviceType.isInput
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

func getVolume(deviceID: AudioDeviceID, type: String?) {
    let deviceType = getDeviceType(deviceID: deviceID)
    let isInput: Bool
    
    if let type = type {
        guard let inputType = parseTypeArgument(type) else {
            log("Invalid type. Specify 'input' or 'output'.", isError: true)
            return
        }
        isInput = inputType
        
        if isInput && !deviceType.isInput {
            log("This device does not support input", isError: true)
            return
        } else if !isInput && !deviceType.isOutput {
            log("This device does not support output", isError: true)
            return
        }
    } else {
        // default to output if available, otherwise input
        isInput = !deviceType.isOutput && deviceType.isInput
    }
    
    guard let volumes = getVolumeWithFallback(deviceID: deviceID, isInput: isInput) else {
        log("No volume available for this device.", isError: true)
        return
    }
    
    var seen = Set<Float32>()
    let uniqueVolumes = volumes.filter { vol in
        if seen.contains(vol) {
            return false
        } else {
            seen.insert(vol)
            return true
        }
    }
    
    let volumeStrings = uniqueVolumes.map { "\($0)" }
    print(volumeStrings.joined(separator: "\t"))
}

func setVolume(deviceID: AudioDeviceID, level: Float32, type: String?) {
    let deviceType = getDeviceType(deviceID: deviceID)
    let isInput: Bool
    
    if let type = type {
        guard let inputType = parseTypeArgument(type) else {
            log("Invalid type. Specify 'input' or 'output'.", isError: true)
            return
        }
        isInput = inputType
        
        if isInput && !deviceType.isInput {
            log("This device does not support input", isError: true)
            return
        } else if !isInput && !deviceType.isOutput {
            log("This device does not support output", isError: true)
            return
        }
    } else {
        isInput = !deviceType.isOutput && deviceType.isInput
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
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: newVolume)), &newVolume) == noErr {
                log("Successfully set main volume to \(level)", isDebug: true)
                return
            }
        }
    }
    
    // fallback to channel-based volume
    if channelCount > 0 {
        let volumes = [Float32](repeating: level, count: channelCount)
        if setChannelVolume(deviceID: deviceID, volumes: volumes, scope: scope) {
            log("Successfully set volume for all \(channelCount) channels to \(level)", isDebug: true)
        } else {
            log("Failed to set volume", isError: true)
        }
    } else {
        log("No channels available to set volume on.", isError: true)
    }
}

func resolveDevice(_ arg: String) -> AudioDeviceID? {
    if let id = UInt32(arg) {
        if let deviceName = getDeviceName(deviceID: id) {
            log("Selected device: \(deviceName)", isDebug: true)
            return id
        } else {
            log("No device matching '\(arg)' was found.", isError: true)
            exit(1)
        }
    }
    
    // string-based search
    let lowerArg = arg.lowercased()
    let devices = getAllDevices()
    for device in devices {
        if device.name.lowercased().contains(lowerArg) {
            log("Resolved '\(arg)' => \(device.name) (id: \(device.id))", isDebug: true)
            return device.id
        }
    }
    
    log("No device matching '\(arg)' was found.", isError: true)
    exit(1)
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
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceIDs) == noErr else {
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

func parseCommandLine() -> Action {
    let action = CommandLine.arguments[safe: 1]?.lowercased() ?? ""
    
    switch action {
    case "list":
        return .list
    case "get":
        guard let arg = CommandLine.arguments[safe: 2], let deviceID = resolveDevice(arg) else {
            return .invalid("Usage: volctl get <device_id|device_name> [type: input|output]")
        }
        let type = CommandLine.arguments[safe: 3]
        return .get(deviceID: deviceID, type: type)
    case "set":
        guard let arg = CommandLine.arguments[safe: 2],
              let levelStr = CommandLine.arguments[safe: 3],
              let level = Float32(levelStr),
              level >= 0, level <= 1,
              let deviceID = resolveDevice(arg) else {
            return .invalid("Usage: volctl set <device_id|device_name> <level (0.0-1.0)> [type: input|output]")
        }
        
        let type = CommandLine.arguments[safe: 4]
        return .set(deviceID: deviceID, level: level, type: type)
    case "mute":
        guard let arg = CommandLine.arguments[safe: 2],
              let deviceID = resolveDevice(arg) else {
            return .invalid("Usage: volctl mute <device_id|device_name> [on|off|toggle] [type: input|output]")
        }
        let state = CommandLine.arguments[safe: 3]
        let type = CommandLine.arguments[safe: 4]
        return .mute(deviceID: deviceID, state: state, type: type)
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
        print("\(device.id)\t\(typeDescription)\t\(device.name)")
    }
}

if CommandLine.argc < 2 {
    print("""
    Get or Set volume levels or mute state for macOS audio devices
    Usage: volctl <command> [args]

    Commands:
        list                           List all audio devices (tab-separated)
        get <device> [type]            Get volume level for a device (type is optional)
        set <device> <level> [type]    Set volume level for a device (0.0-1.0)
        mute <device> [on|off] [type]  Control mute state (omitting action will toggle)

    Notes:
        <device> can be an ID number or a string (partial ok)
        When using a string to select device, the first match will be used
    """)
    exit(0)
}

let action = parseCommandLine()

switch action {
case .list:
    listDevices()
case .get(let deviceID, let type):
    getVolume(deviceID: deviceID, type: type)
case .set(let deviceID, let level, let type):
    setVolume(deviceID: deviceID, level: level, type: type)
case .mute(let deviceID, let state, let type):
    exit(handleMuteCommand(deviceID: deviceID, state: state, type: type) ? 0 : 1)
case .invalid(let error):
    log(error, isError: true)
    exit(1)
}
