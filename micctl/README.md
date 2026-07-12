# micctl

CLI for Core Audio **input-device** controls. macOS's scriptable surface
(`osascript -e 'set volume input volume …'`) only touches the default input
device's volume scalar — and some devices (e.g. Shure's MOTIV Mix Virtual)
silently ignore even that. `micctl` talks to the device's own properties:
`kAudioDevicePropertyMute`, `VolumeScalar`, and `DeviceIsRunningSomewhere`.

```
micctl list                          # all devices: input channels, mute, volume
micctl get-mute   <device-name>      # prints 1 (muted) / 0
micctl set-mute   <device-name> on|off
micctl get-volume <device-name>      # 0.0–1.0
micctl set-volume <device-name> <0.0-1.0>
micctl get-running <device-name>     # 1 if something is recording from it
```

Device names match exactly first, then case-insensitive substring
(`micctl get-mute mv7` finds "Shure MV7+"). Devices vary in which element
carries the control, so main element and channels 1–2 are all tried.

Notes from the field:

- The Shure MV7+'s touch-panel mute **is** visible and settable through
  `kAudioDevicePropertyMute` on the physical device.
- Virtual passthrough devices may expose mute read-only (MOTIV Mix Virtual
  does) — control the physical device instead.
- `get-running` reflects *any* process recording from the device, not who.
