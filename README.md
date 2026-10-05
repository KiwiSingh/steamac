# Steamac — SteamOS on Apple Silicon

Run Valve’s ARM64 SteamOS in a lightweight virtual machine on your Mac, with accelerated graphics through Metal. No Parallels Desktop subscription is required.

This is **[KiwiSingh’s fork](https://github.com/KiwiSingh/steamac)** of **[fxgl/steamac](https://github.com/fxgl/steamac)**. The original project provides the launcher, VM integration, SteamOS provisioning, and much of the graphics stack. This fork adds selectable external SSD storage, controller identity and mapping fixes, and an experimental alternative Vulkan driver.

**MoltenVK is the default.** KosmicKrisp remains experimental: it rendered the Steam updater in testing, but failed to display the main Steam interface reliably. It is not a recommended gameplay path.

## What has been tested

- SteamOS disk creation and Steam updates on an external SSD.
- Steam’s setup and main interface through MoltenVK.
- Switching into the Plasma desktop and returning to Gaming Mode on the tested Steam Frame image.
- Desktop mouse clicks in windowed/fullscreen mode and Flatpak sandbox startup, including Chromium launch.
- A Bluetooth Sony DualSense, recognized by Steam as a **PS5 Controller**, with corrected face buttons, analog/digital triggers, stick axes, stick clicks, and PS button.
- **Digimon Story: Time Stranger:** the fork’s owner reports successful gameplay on an Apple M3 Mac and confirms the corrected controller mapping works. This is one user’s result, not a benchmark or a guarantee for other Macs or games.

Broad DirectX 12 compatibility, ray tracing, and other games remain unverified. The source-built DX12 capability check is diagnostic evidence, not proof of game compatibility. Games whose anti-cheat blocks virtual machines may not work.

## Install a release

Download the launcher from **[this fork’s Releases](https://github.com/KiwiSingh/steamac/releases)**. Read the release notes for signing status and the exact bundled components. The desktop, mouse, and Flatpak startup fixes are included in [`v1.2.3-preview.1`](https://github.com/KiwiSingh/steamac/releases/tag/v1.2.3-preview.1). Early fork builds are prereleases and are ad-hoc signed, **not Apple-notarized**; downloaded builds may require approval in macOS **System Settings → Privacy & Security**, or you can build locally instead.

1. Extract the app and place **FX Steam Launcher.app** in your Applications folder. An Applications folder on an external SSD also works.
2. Launch it. Choose **Create New Disk…**, then **Choose SSD…** to select a mounted writable external SSD or a folder on it. **Location…** selects a custom image filename.
3. Choose the home partition size and create the disk. The app downloads SteamOS from Valve, verifies its signed bundle, and creates the image. Docker is not required for this GUI workflow.
4. Boot SteamOS, finish setup, sign in to Steam, and install a game you own. Connect your controller **before booting**.

The disk is a sparse **image file**, not a write to the physical drive. The app does not erase your external SSD. Provisioning files and download caches stay beside the selected image. A disconnected drive is an error; it does not silently fall back to internal storage. Existing saved disk locations remain in use until you change them in Settings.

For a desktop shortcut, launch the installed app directly or drag it into the Dock. The owner’s local `SteamOS.app` shortcut is specific to their machine and is not part of the portable release.

## Requirements

For this fork’s packaged launcher:

- An Apple Silicon Mac running **macOS 26 or newer**.
- A mounted writable external SSD with enough space for SteamOS, temporary download/provisioning files, and your games. Reserve at least about 25 GB for initial setup, plus game storage. A larger logical home partition does not reserve all of that space immediately.
- Internet access and your own Steam account/game licenses.

The upstream launcher targets older macOS versions; this fork’s current launcher and optional KosmicKrisp build target macOS 26+. The tested host was an Apple M3 running macOS 27.2. Other configurations need testing.

## Controllers

The launcher bridges macOS GameController input into a Linux virtio-input device. It preserves the selected controller’s identity:

| Controller | Guest identity |
| --- | --- |
| DualSense | Sony `054c:0ce6` |
| DualSense Edge, when identified by macOS | Sony `054c:0df2` |
| DualShock profile | Sony `054c:09cc`, representative of a DualShock 4 |
| Other supported extended gamepads | Reported name with Steamac’s virtual ID; no fabricated Xbox 360 identity |

At startup, the launcher waits briefly for macOS’s asynchronous controller discovery before fixing the guest device’s identity. A controller connected after boot, or a different model selected later, requires a **VM restart**. Reconnecting the same selected profile is supported.

Sony button/axis ordering matches Steam’s PS5 mapping. In particular, the right stick is separate from L2/R2. Generic controllers keep the semantic evdev layout. Settings → Controller offers controller selection, button swapping, and deadzone adjustment.

This is **not USB/HID passthrough**. Rumble, adaptive triggers, gyro, touchpad, speaker/headphone output through the controller, and LED control are not implemented. DualSense Edge/DualShock identities are implemented but have not had the same physical runtime validation as DualSense.

## Build from source

Keep the checkout on your external SSD so the repository’s build output and caches stay there.

```sh
git clone https://github.com/KiwiSingh/steamac.git
cd steamac

# Replace this with your own mounted external SSD.
export STEAMAC_STORAGE_VOLUME="/Volumes/My External SSD"
./build.sh

# Launch the generated app, or use the development launcher:
./run.sh
```

Build prerequisites include full **Xcode 26+**, Homebrew, rustup, and Docker Desktop or OrbStack with privileged arm64 containers. The host scripts use packages including `meson ninja pkgconf dtc xz lld libepoxy vulkan-loader vulkan-headers`; individual components check additional prerequisites. Homebrew and Docker manage their own storage separately from the repository’s cache directories.

```sh
./build.sh host     # host drivers, VM library, launcher and app
./build.sh guest    # guest kernel, Mesa, initramfs, layer and disk
./run.sh --display 1920x1080 --cpus 8 --mem 16384
```

`STEAMAC_DISK_PATH` selects an existing image for `run.sh`. `STEAMAC_DISK_DIR` selects the Docker image-building destination. Paths may contain spaces. See [fork setup](docs/fork-setup.md) for storage checks and build details.

### Experimental KosmicKrisp

Build the default MoltenVK path first, then the experimental driver:

```sh
./build.sh host
STEAMAC_VULKAN_DRIVER=kosmickrisp ./build.sh host
STEAMAC_VULKAN_DRIVER=kosmickrisp ./run.sh
```

The app bundles the experimental ICD only when it has been built. Unknown or missing drivers are refused rather than silently replaced. Experimental guest presentation requires `MESA_VK_WSI_DEBUG=buffer` on both Steam and Gamescope services; see [the detailed status](docs/fork-setup.md). Leave MoltenVK selected for normal use.

The graphics path is:

```text
Game → Proton/DXVK or vkd3d-proton → guest Vulkan/Venus
     → virtio-gpu → virglrenderer → Vulkan loader → MoltenVK → Metal
```

KosmicKrisp can replace the final Vulkan driver for experiments. Its native-texture/shared-memory fixes are retained, with GPU upload/readback regression checks.

## Useful controls and settings

| Action | Shortcut |
| --- | --- |
| Settings | Command+, |
| Full screen | Control+Command+F |
| Capture/release mouse | Control+Command+G |
| Release mouse capture | Control+Option |
| Metal performance HUD | Control+Command+P |

Closing the VM window requests guest shutdown. Settings identify which changes require a restart. Sound is muted while the launcher is in the background by default; change that under General if needed.

The normal **2D Steam interface** is the default. Frame VR flags are only enabled by `STEAMAC_STEAM_VR_UI=1`, for experiments with a working VR compositor.

SSH is off by default in the app. Enable it under **Settings → Advanced** when needed. The app generates a per-disk password stored in macOS Keychain; do not assume a shared default password. The development scripts have different SSH defaults.

Crash reporting and **Help → Report a Problem** are inherited from upstream and use upstream infrastructure. Review the settings and disclosure before enabling or submitting reports; use this fork’s [GitHub issues](https://github.com/KiwiSingh/steamac/issues) for fork-specific problems. `--no-crash-reports` disables automatic reporting for one launch.

## Troubleshooting

- **No controller:** connect it before boot and restart the VM. Check the selected device in Settings → Controller.
- **Wrong button/trigger behavior:** use a current fork build; early builds exposed PS5 IDs with a generic layout. Restore default controller swapping before diagnosing game-specific Steam Input remaps.
- **Black screen on KosmicKrisp:** return to MoltenVK. The experimental driver’s browser-buffer presentation failure is unresolved.
- **Download/validation stays near completion:** inspect Steam’s Downloads page. A shader-cache download can continue after the game is fully installed; in the tested session it completed without error. Do not delete game files just because the percentage pauses.
- **Spoken “dummy output module” message:** SteamOS’s Speech Dispatcher fallback can play a test recording when menu narration requests speech without a working synthesizer. It is unrelated to headphone hardware. Turn off narration if unwanted; the owner’s local narration setting is not a global release default.

Logs live under `~/Library/Logs/es.fxgam.steamac/`. For a useful bug report, include the fork version, Mac model/macOS version, selected driver, game/Proton version, connection type, and relevant logs. Remove credentials and account details first.

## Validation and release scope

Controller mapping tests decode emitted input through the observed Steam PS5 layout, including stick/trigger isolation. Host Vulkan checks cover renderer initialization and shared-memory export; KosmicKrisp’s GPU test also checks optimal-texture uploads and readback. These checks complement, rather than replace, real-game testing.

```sh
python3 scripts/test/fork-check.py
scripts/test/controller-check.sh
scripts/test/external-storage-check.sh "/Volumes/My External SSD"
```

Initial fork binaries reuse the upstream v1.1 guest kernel, initramfs, and patched MoltenVK library. Release notes identify any guest-layer repacking and the exact source revision. They do not include a personal SteamOS disk, Steam credentials, installed games, or the owner’s local wrapper paths.

## Credits and licensing

Thanks to **fxgl** for Steamac, and the contributors to libkrun, UTM’s virglrenderer/MoltenVK forks, Mesa/Venus, FEX, Proton, DXVK, and vkd3d-proton. Steam and SteamOS are Valve products; this fork is not affiliated with or endorsed by Valve or Apple.

The repository currently has no top-level license file. Third-party components retain their own licenses; bundled license notices and source references must be preserved when redistributing them. No new repository-wide license is asserted by this fork.

## Desktop Mode

Choose **Switch to Desktop** in Steam, then **Return to Gaming Mode** on the Plasma desktop to return. Keep **Mouse → Auto** selected: the launcher maps pointer input to the scaled nested desktop, including fullscreen black bars.

Discover-installed apps such as Chromium and Vesktop use Flatpak. Builds before `v1.2.3-preview.1` could show a loading icon and then exit with `bwrap: Can't mount proc on /newroot/proc: Operation not permitted`. The new guest layer mounts an intact procfs at `/run/steamac/proc`, allowing application sandboxes to create their own procfs while SteamOS keeps its synthesized `/proc/cmdline`. It preserves Flatpak’s sandbox rather than disabling it.

Upgrade the app while SteamOS is shut down, then reboot your existing image. No SteamOS download or game reinstall is needed. The fix has been tested on the owner’s Steam Frame image; other image revisions and every Flatpak application remain unverified. Local account/password changes are personal VM state and are not bundled in releases.
