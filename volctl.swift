import CoreAudio
import Foundation

func printError(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

func parseTypeArgument(_ type: String?) -> Bool? {
    guard let type = type?.lowercased() else { return false }
    switch type {
    case "input": return true
    case "output": return false
    default: return nil
    }
}

func isValidDeviceID(deviceID: AudioDeviceID) -> Bool {
    var deviceIDs = [AudioDeviceID]()
    var propertySize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &propertySize
    )
    guard status == noErr else { return false }
    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    deviceIDs = Array(repeating: AudioDeviceID(), count: deviceCount)
    let status2 = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &propertySize,
        &deviceIDs
    )
    return status2 == noErr && deviceIDs.contains(deviceID)
}

func listDevices() {
    var deviceIDs = [AudioDeviceID]()
    var propertySize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &propertySize
    )
    if status != noErr {
        printError("Error retrieving device list size: \(status)")
        return
    }
    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    deviceIDs = Array(repeating: AudioDeviceID(), count: deviceCount)
    let status2 = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &propertySize,
        &deviceIDs
    )
    if status2 != noErr {
        printError("Error retrieving device list: \(status2)")
        return
    }
    var devices: [(id: AudioDeviceID, name: String, type: String)] = []
    for deviceID in deviceIDs {
        let name = getDeviceName(deviceID: deviceID) ?? "Unknown"
        let isOutput = isDeviceOutput(deviceID: deviceID)
        let isInput = isDeviceInput(deviceID: deviceID)
        
        var typeDescription = "Unknown"
        if isOutput && isInput {
            typeDescription = "In/Out"
        } else if isOutput {
            typeDescription = "Output"
        } else if isInput {
            typeDescription = "Input"
        }
        devices.append((id: deviceID, name: name, type: typeDescription))
    }
    devices.sort {
        if $0.type == $1.type {
            return $0.name.lowercased() < $1.name.lowercased()
        }
        return $0.type < $1.type
    }
    for device in devices {
        print("\(device.id)\t\(device.type)\t\(device.name)")
    }
}

func isDeviceOutput(deviceID: AudioDeviceID) -> Bool {
    return deviceHasStream(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
}

func isDeviceInput(deviceID: AudioDeviceID) -> Bool {
    return deviceHasStream(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
}

func deviceHasStream(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
    var propertySize: UInt32 = 0
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyDataSize(
        deviceID,
        &address,
        0,
        nil,
        &propertySize
    )
    guard status == noErr, propertySize > 0 else { return false }
    var data = Data(count: Int(propertySize))
    let status2 = data.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return kAudioHardwareUnspecifiedError
        }
        return AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            baseAddress
        )
    }
    guard status2 == noErr else { return false }
    let audioBufferList = data.withUnsafeBytes { buffer in
        buffer.bindMemory(to: AudioBufferList.self).baseAddress
    }
    guard let bufferList = audioBufferList else {
        return false
    }
    return bufferList.pointee.mNumberBuffers > 0
}

func getDeviceName(deviceID: AudioDeviceID) -> String? {
    var name: CFString? = nil
    var propertySize = UInt32(MemoryLayout<CFString?>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = withUnsafeMutablePointer(to: &name) { namePointer in
        namePointer.withMemoryRebound(to: UInt8.self, capacity: 1) { reboundPointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &propertySize,
                reboundPointer
            )
        }
    }
    if status == noErr, let name = name {
        return name as String
    } else {
        printError("Error retrieving name for device ID \(deviceID): \(status)")
        return nil
    }
}

func getVolume(deviceID: AudioDeviceID, isInput: Bool) -> Float32? {
    var volume: Float32 = 0
    var size = UInt32(MemoryLayout.size(ofValue: volume))
    let scope: AudioObjectPropertyScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &size,
        &volume
    )
    if status == noErr {
        return volume
    } else {
        printError("Error getting volume: \(status)")
        return nil
    }
}

func setVolume(deviceID: AudioDeviceID, volume: Float32, isInput: Bool) {
    let scope: AudioObjectPropertyScope = isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var newVolume = volume
    let status = AudioObjectSetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        UInt32(MemoryLayout.size(ofValue: newVolume)),
        &newVolume
    )
    if status != noErr {
        printError("Error setting volume: \(status)")
        exit(1)
    }
}

if CommandLine.argc < 2 {
    printError("""
    Get or Set volume level for macOS audio devices
    Usage: volctl <list|get|set> [device_id] [level] [type: input|output]
        list                            List all audio devices with IDs, types, and names (tab-separated)
        get <device_id> [type]          Get volume level for a device (type is optional)
        set <device_id> <level> [type]  Set volume level for a device (0.000-1.000)
    """)
    exit(1)
}

let action = CommandLine.arguments[1].lowercased()
switch action {
case "list":
    listDevices()
case "get":
    guard CommandLine.argc >= 3, let deviceID = UInt32(CommandLine.arguments[2]) else {
        printError("Usage: volctl get <device_id> [type: input|output]")
        exit(1)
    }
    if !isValidDeviceID(deviceID: deviceID) {
        printError("Invalid device ID: \(deviceID)")
        exit(1)
    }
    let type = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
    guard let isInput = parseTypeArgument(type) else {
        printError("Invalid type (must be one of: 'input', 'output')")
        exit(1)
    }
    if let currentVolume = getVolume(deviceID: deviceID, isInput: isInput) {
        print(currentVolume)
    } else {
        printError("Unable to get \(type ?? "output") volume for the specified device.")
    }
case "set":
    guard CommandLine.argc >= 4,
          let deviceID = UInt32(CommandLine.arguments[2]),
          let volume = Float32(CommandLine.arguments[3]),
          volume >= 0, volume <= 1 else {
        printError("Usage: volctl set <device_id> <volume level (0.0-1.0)> [type: input|output]")
        exit(1)
    }
    if !isValidDeviceID(deviceID: deviceID) {
        printError("Invalid device ID: \(deviceID)")
        exit(1)
    }
    let type = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : nil
    guard let isInput = parseTypeArgument(type) else {
        printError("Invalid type. Specify 'input' or 'output'.")
        exit(1)
    }
    setVolume(deviceID: deviceID, volume: volume, isInput: isInput)
default:
    printError("Invalid action (must be one of: 'list', 'get', 'set')")
    exit(1)
}
