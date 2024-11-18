# volctl

Get or Set volume level for macOS audio devices.

Support precise floating point values such as `0.273`

Some devices are "hybrid" and register as both an Input and Output device. For such devices, an additional `type` argument can be supplied to indicate which level you intend to operate on.

```
Usage: volctl <list|get|set> [device_id] [level] [type: input|output]
    list                            List all audio devices with IDs, types, and names (tab-separated)
    get <device_id> [type]          Get volume level for a device (type is optional)
    set <device_id> <level> [type]  Set volume level for a device (0.000-1.000)
```
