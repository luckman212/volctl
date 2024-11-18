<img width=192 src=icon.png>

# volctl

This is a commandline tool to Get or Set the volume level for a macOS audio device.

In contrast to the often suggested `osascript -e "output volume of (get volume settings)"`, it supports both getting and setting precise floating point values such as `0.273`

**N.B.** Some devices are "hybrid" and register as both an Input and Output device. For such devices, an additional `type` argument can be supplied to indicate which level you intend to operate on.

```
Usage: volctl <list|get|set> [device_id] [level] [type: input|output]
    list                            List all audio devices with IDs, types, and names (tab-separated)
    get <device_id> [type]          Get volume level for a device (type is optional)
    set <device_id> <level> [type]  Set volume level for a device (0.000-1.000)
```

To use, download the latest [release](https://github.com/luckman212/volctl/releases) and place `volctl` in your `$PATH` somewhere. I suggest `/usr/local/bin`.

To compile from source, clone the repo and run:

```
swiftc -O -o volctl volctl.swift
```
