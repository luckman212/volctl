<p align="left"><img height=160 src="./icon.png" /></p>

# volctl

This is a commandline tool to Get or Set the volume level for a macOS audio device. It also supports controlling the mute state.

In contrast to the often suggested `osascript -e "output volume of (get volume settings)"`, it supports both getting and setting precise floating point values such as `0.273`

**N.B.** Some devices are "hybrid" and register as both an Input and Output device. For such devices, an additional `type` argument can be supplied to indicate which level you intend to operate on.

```
Usage: volctl <command> [args]

Commands:
    list                           List all audio devices (tab-separated)
    get <device> [type]            Get volume level for a device (type is optional)
    set <device> <level> [type]    Set volume level for a device (0.0-1.0)
    mute <device> [on|off] [type]  Control mute state (omitting action will toggle)

Notes:
    <device> can be an ID number or a string (partial ok)
    When using a string to select device, the first match will be used
```

If a device has multiple streams and they are set at different levels (e.g. L/R balance is not equal) then all levels will be output in tab-separated format.

### Installing

Download the latest [release](https://github.com/luckman212/volctl/releases) and place `volctl` in your `$PATH` somewhere. I suggest `/usr/local/bin`.

Or, to compile from source, clone the repo and run:

```
swiftc -O -o volctl volctl.swift
```

### Examples

```
$ volctl list
61  Output  Audioengine 2+
140 Output  DELL S2721QS
95  In/Out  Jump Desktop Audio
99  In/Out  Jump Desktop Microphone
134 Input   Logitech Webcam C925e
113 Output  Mac mini Speakers
103 In/Out  Microsoft Teams Audio
55  Output  RODE NT-USB
67  Input   RODE NT-USB
127 In/Out  ZoomAudioDevice
```

```
$ volctl get logi
0.8
```

```
$ DEBUG=true volctl set logi 0.65
Resolved 'logi' => Logitech Webcam C925e (id: 134)
Successfully set main volume to 0.65
```
