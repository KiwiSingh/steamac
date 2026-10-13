# Steamac — Kiwi Build

**English** · [Русский](README.ru.md) · [简体中文](README.zh.md)

A personal fork of [fxgl/steamac](https://github.com/fxgl/steamac), focused on quality-of-life improvements for running SteamOS games on Apple silicon Macs.

The current release is based on **Steamac 1.9** and brings all upstream improvements from releases 1.8, 1.8.1, 1.8.2, and 1.9 alongside Kiwi enhancements (75% automatic RAM allocation, BepisBridge, Discord Rich Presence, GE-Proton installer, and ReShade/Asset Mod management).

> **Latest Kiwi release:** `v1.9-kiwi.1` ([download](https://github.com/KiwiSingh/steamac/releases/tag/v1.9-kiwi.1))

Kiwi Build 1.9 pairs with [BepisLoader 2.3.4+](https://github.com/KiwiSingh/BepisLoader/releases/tag/v2.3.4) for mod management and SteamOS integration.

## New in Kiwi Build 1.9 (`v1.9-kiwi.1`)

### Upstream 1.8 – 1.9 Features Integrated
- **DirectX 12 Feature Level 12_0 on KosmicKrisp (macOS 26+)**:
  - Implements real tiled resources (D3D12 tiled resources tier 2) on Metal 4 placement sparse resources: sparse binding of images and buffers, shader residency queries (`CheckAccessFullyMapped`), unbound tiles reading zero, and sampler min/max reduction.
  - Enables DirectX 12 games that strictly require feature level 12_0 (such as *Resident Evil 2*) to launch and access enhanced rendering paths.
- **Multichannel Audio up to 12 Channels**:
  - Automatically reads speaker layouts configured in macOS Audio MIDI Setup at VM boot (supporting 5.1, 7.1, 5.1.2, and 7.1.4 with height speakers).
  - Routes PCM channels directly to physical hardware speakers with automatic downmixing when physical channels are missing.
- **Instant Output Switching**:
  - Audio follows default output changes (such as connecting AirPods or selecting a device in macOS Control Center) immediately without lag.
- **Multiplayer Controller Support**:
  - Additional connected gamepads beyond the primary controller automatically map to guest player slots 2–4.
- **MoltenVK & DXVK Compatibility Fixes**:
  - *Counter-Strike 2*: Empty/null descriptor sets bound via `vkCmdBindDescriptorSets` no longer crash the VM.
  - *Left 4 Dead 2 & DXVK*: Fragment shaders writing unsigned values to signed-integer render targets now compile correctly without shader errors.
- **KosmicKrisp Stability & Diagnostics**:
  - *Dota 2 & CS2*: Query pool exhaustion resolved by chunking occlusion results and sharing timestamp counter heaps.
  - *M3+ GPU Startup Fix*: Render pass target textures are registered in Metal 4 residency sets, resolving startup GPU timeouts.
  - Detailed diagnostic reporting naming the exact GPU workload and driver failure reason on timeouts.
- **Clearer Network & Certificate Errors**:
  - VPN, proxy, and TLS issues provide actionable diagnostic messages rather than raw system error codes.
  - Valve development-signed builds (e.g., `rc` branch) are identified clearly with fallback suggestions.
- **Metal Compiler Cache Fallback**:
  - Automatically redirects to launcher cache if app compiler cache directories are read-only.
- **UI Localization**:
  - Launcher windows, menus, settings, and progress notifications now support Russian and Simplified Chinese based on system language preferences.

### Maintained Kiwi Enhancements
- **75% Automatic VM Memory Allocation**: Retains generous host memory sizing (up to 75% of physical RAM, 4–16 GiB) while reserving adequate memory for macOS and unified GPU workloads.
- **BepisBridge Integration**: Seamless integration with BepisLoader for mod installation, ReShade injection, and game library inspection.
- **Discord Rich Presence**: Native macOS Discord IPC status updates with active game art and playtime tracking.
- **GE-Proton Runtime Downloader**: One-click GE-Proton installation into SteamOS compatibility tools directly from Settings.
- **Combined Asset Mod Profiles & ReShade**: Full support for checked asset replacement, MBE CSV tables, ADX2 audio banks, and DXGI ReShade runtime injection.

---

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

This gives memory-hungry games more room inside SteamOS while still reserving memory for macOS and shared GPU resources. You can still override the automatic value manually in Settings.

### Kiwi Build updater

The built-in update checker follows releases from this fork (`KiwiSingh/steamac`) rather than upstream. Release tags use the `vX.Y.Z-kiwi.N` format (e.g. `v1.9-kiwi.1`).

### BepisBridge integration

Kiwi Build includes **BepisBridge** setup in Settings to support integration with [BepisLoader](https://github.com/KiwiSingh/BepisLoader). The setup provisions per-VM SSH authentication and virtio communication, enabling BepisLoader to interact directly with the running SteamOS guest.

---

## Download

Prebuilt Kiwi releases are available from:

https://github.com/KiwiSingh/steamac/releases

The current release is:

**Steamac 1.9 Kiwi Build 1 — `v1.9-kiwi.1`**

The release ZIP is ad-hoc signed and is **not notarized with an Apple Developer ID**.

## Building

This fork follows the upstream Steamac build system. Refer to the source tree and upstream documentation for build requirements and instructions.

The Kiwi-specific changes are intentionally kept small and isolated from upstream functionality.

## Upstream

Steamac is developed by **fxgl**:

https://github.com/fxgl/steamac

This fork tracks the upstream project and adds Kiwi-specific changes on top. Features that are subsequently implemented or superseded upstream defer to the upstream implementation rather than maintain unnecessary parallel code.

## License

See the repository's existing license and upstream Steamac licensing information.
