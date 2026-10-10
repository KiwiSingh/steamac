# Steamac — Kiwi Build

A personal fork of [fxgl/steamac](https://github.com/fxgl/steamac), focused on quality-of-life improvements for running SteamOS games on Apple silicon Macs.

The current release is based on **Steamac 1.7.6** and retains the upstream project's native DualSense passthrough, MetalFX support, Retina resolution support, and other improvements.

> **Latest Kiwi release:** `v1.7.6-kiwi.5`

## New in Kiwi Build 5

The bundled SteamOS guest agent now advertises `assetModInstallV1`, enabling [BepisLoader 2.1.0](https://github.com/KiwiSingh/BepisLoader/releases/tag/v2.1.0) to install validated asset mods through the existing bridge. The first adapter supports DDS textures for the pinned x64 Digimon Story Time Stranger build under ARM64 Proton; eye-texture replacement was confirmed in gameplay.

Quit the VM normally before replacing the Steamac app. Restart it using this release's bundled guest layer to obtain the capability; no disk recreation is required. Close the game when installing/disabling mods. Steam may remain open. Copy BepisLoader's reported setting manually into Steam Launch Options. Unsupported builds, code payloads and unsafe paths remain blocked. Current recovery-inventory work and Build 4's BepisBridge status fix are retained.

Packaging signs components individually and the app last; it does not use `codesign --deep`.

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
v1.7.6-kiwi.5
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

**Steamac 1.7.6 Kiwi Build 5 — `v1.7.6-kiwi.5`**

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
