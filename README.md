# Steamac — Kiwi Build

A personal fork of [fxgl/steamac](https://github.com/fxgl/steamac), focused on quality-of-life improvements for running SteamOS games on Apple silicon Macs.

The current release is based on **Steamac 1.7.6** and retains the upstream project's native DualSense passthrough, MetalFX support, Retina resolution support, and other improvements.

> **Latest Kiwi release:** `v1.7.6-kiwi.3`

## What's different in the Kiwi Build?

### More automatic VM memory

The Kiwi Build increases Steamac's automatic VM memory allocation from **50% to 75% of host RAM**, while retaining the existing 4 GiB minimum and 16 GiB maximum.

Typical automatic allocations:

| Mac RAM | SteamOS VM |
| ---: | ---: |
| 8 GB | 6 GiB |
| 16 GB | 12 GiB |
| 18 GB | ~14 GiB |
| 24 GB+ | 16 GiB |

This gives memory-hungry games more room inside SteamOS while still reserving memory for macOS and shared GPU resources.

You can still override the automatic value manually.

### Kiwi Build updater

The built-in update checker follows releases from this fork rather than the upstream repository.

Kiwi release tags use the format:

```text
vX.Y.Z-kiwi.N
```

For example:

```text
v1.7.6-kiwi.3
```

The updater has been extended to recognize these tags while retaining Steamac's underlying version comparison.

### BepisBridge integration

Kiwi Build 3 adds **BepisBridge** setup in Steamac Settings to support integration with [BepisLoader](https://github.com/KiwiSingh/BepisLoader). The setup flow provisions per-VM SSH authentication, enabling BepisLoader to interact with a running SteamOS guest. Existing virtio bridge functionality is retained.

**Validated:** Steamac launches and boots SteamOS, the BepisBridge setup control is available, and BepInEx mods work with *Digimon World: Next Order* (AppID `1530160`) through the integrated workflow. Other games and mod frameworks may require additional testing.

## Steamac 1.7.6 features

The Kiwi Build includes the upstream Steamac 1.7.6 improvements, including:

- **DualSense / DualSense Edge raw HID passthrough**
  - Touchpad
  - Gyroscope
  - Mute button
  - Player and mute LEDs
  - Lightbar control
  - Rumble
  - Adaptive triggers
- **MetalFX super resolution**
- **Optional Retina resolution**
- Increased VM file-descriptor limits to prevent GPU failures caused by descriptor exhaustion
- Existing Steamac external-storage, Desktop Mode, controller, and SteamOS integration features

DualSense support in Kiwi Build 1.7.6 comes from Steamac's upstream raw-HID implementation rather than the older experimental controller implementation previously maintained in this fork.

## Tested configuration

Kiwi Build 3 has been tested on a **16 GB Apple silicon Mac** with:

- SteamOS booting successfully
- Automatic VM memory correctly selecting **12288 MiB**
- DualSense passthrough
- Built-in update checks against `KiwiSingh/steamac`
- Recognition of `vX.Y.Z-kiwi.N` release tags
- BepisBridge Settings control and successful BepInEx mod test with Digimon World: Next Order

## Download

Prebuilt Kiwi releases are available from:

https://github.com/KiwiSingh/steamac/releases

The current release is:

**Steamac 1.7.6 Kiwi Build 3 — `v1.7.6-kiwi.3`**

The release ZIP is ad-hoc signed and is **not notarized with an Apple Developer ID**.

## Building

This fork follows the upstream Steamac build system. Refer to the source tree and upstream documentation for build requirements and instructions.

The Kiwi-specific changes are intentionally kept small and isolated from upstream functionality.

## Upstream

Steamac is developed by **fxgl**:

https://github.com/fxgl/steamac

This fork tracks the upstream project and adds Kiwi-specific changes on top. Features that are subsequently implemented or superseded upstream are intended to defer to the upstream implementation rather than maintain unnecessary parallel code.

## License

See the repository's existing license and upstream Steamac licensing information.
