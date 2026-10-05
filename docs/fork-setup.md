# External SSD / selectable Vulkan fork

This fork changes the default storage and keeps MoltenVK as the default Vulkan implementation. KosmicKrisp is experimental. The upstream game compatibility results do not validate this fork.

## Storage

In **Create SteamOS Disk**, click **Choose SSD…** and select any mounted writable external drive (or a folder on it). **Location…** selects a custom image filename. When exactly one external drive is mounted, it is suggested automatically; when several are mounted, choose explicitly. An existing disk saved in Settings keeps its location.

The disk is a sparse GPT image **file**, not a write to the physical SSD. Existing files are preserved unless the Docker builder's explicit `FORCE_DISK=1` option is used. Temporary rootfs, partial image and provisioning payload stay beside the chosen image. Download caches and the creation lock live at `<selected drive>/steamac/cache`. No named drive is required and missing drives never fall back to internal storage. Symlinked paths are checked against their actual mounted volume.

For scripts, specify your drive explicitly (quotes preserve spaces):

```sh
STEAMAC_STORAGE_VOLUME="/Volumes/My External SSD" ./run.sh
STEAMAC_STORAGE_VOLUME="/Volumes/My External SSD" ./build.sh
```

Alternatively, `STEAMAC_DISK_PATH` selects the image for `run.sh` and `STEAMAC_DISK_DIR` selects the image directory for Docker builds. Overrides are validated on their own drive, without requiring any other SSD. Docker mounts the selected image directory at `/disk` for creation and verification. Cache locking prevents GUI and CLI creators on the same drive from overwriting temporary images or removing one another's chunks.

Keep the checkout and its work directory on an external drive too. Build scratch and Python, Swift and Rust caches live beside the checkout. Homebrew and Docker manage their own storage separately.

## Vulkan / DirectX 12

Requires Apple Silicon, macOS 26+ and full Xcode 26+. KosmicKrisp is built from Mesa commit `4cf0989083d25b92d02c6fef2bed934ad77b4ecd`, the same Mesa revision as the guest Venus build.

This fork patches KosmicKrisp to expose separate native device-local and host-visible memory types. Optimal textures require native Metal heaps; linear scanout images require host-visible memory that Venus can export as shared memory. Importing every allocation as a host pointer leaves optimal textures without a Metal heap and caused a SIGSEGV in `mtl_copy_from_buffer_to_texture`. The patch also returns binding/allocation errors instead of leaving a null Metal texture.

`host/kosmickrisp/build.sh` runs a real Vulkan regression test: it follows Venus's allocation policy, uploads an imported staging buffer into an optimal image, copies it back and verifies every byte. It checks that linear images only offer shareable memory. The original driver crashed this test with SIGSEGV; the patched driver passes.

Experimental KosmicKrisp guest presentation requires `MESA_VK_WSI_DEBUG=buffer` on both Steam and Gamescope services (MoltenVK uses the normal presentation path): KosmicKrisp does not support color attachments on linear images, so Mesa renders into native textures and copies into shared display buffers. Buffers only advertise shareable memory; virglrenderer remaps unbound exported allocations (including common WSI's memory-type-zero dma-buf sync probe) to a host-import-compatible type. Dedicated images are never remapped.

The launcher now starts the normal 2D Steam gamepad interface. The Frame-only `-deckard` and `-vrgamepadui` arguments are opt-in through `STEAMAC_STEAM_VR_UI=1`. Without a VR compositor those arguments can leave Steam's UI hidden even after successful startup.

MoltenVK is the default at build and launch. `STEAMAC_VULKAN_DRIVER=kosmickrisp ./build.sh host` builds the experimental path; `STEAMAC_VULKAN_DRIVER=kosmickrisp ./run.sh` selects it at launch. The app bundles KosmicKrisp only when its library and manifest exist, and refuses a missing or unknown driver instead of silently selecting another ICD. Build MoltenVK as well before bundling, since every app includes the default driver.

The software desktop fallback has been removed: disabling Xwayland GLamor failed in the current guest, which has no software OpenGL driver. KosmicKrisp successfully rendered the updater but failed to display Steam's main interface because of browser graphics-buffer export errors. It is not currently a usable default.

The rendering path is:
`Proton vkd3d-proton → guest Vulkan/Venus → virglrenderer → Vulkan loader → selected ICD → Metal`.

The host now links the Vulkan **loader**, because Mesa exposes the ICD interface rather than MoltenVK's directly linked Vulkan API. The launcher pins `VK_DRIVER_FILES` to the selected bundled driver manifest before renderer initialization. Bundles contain the loader, ICD, a relative-path manifest, and recursively copied non-system dynamic dependencies. The existing Venus renderer/shared-memory smoke test runs with this ICD selected.

Build prerequisites (the new driver script checks them and does not install them silently):
`meson ninja pkgconf llvm libclc spirv-llvm-translator spirv-tools vulkan-loader vulkan-headers`.
The remaining host builds also need `dtc xz lld libepoxy`, rustup and their existing prerequisites. Guest builds require a running Docker/OrbStack engine with privileged arm64 containers.

Build with `./build.sh`; individual selected driver builds use `host/vulkan/build.sh`. The Homebrew build uses shared LLVM, matching the SPIR-V translator. Mixing statically linked LLVM in `mesa_clc` with the translator's shared LLVM duplicates analysis state and crashes shader generation. Shared LLVM is a build-tool dependency, not a runtime dependency of the KosmicKrisp ICD.

Steam's ARM-compatible Proton supplies vkd3d-proton and DXVK's shared DXGI. Select the compatible Proton version for the game in Steam. No macOS Wine DLLs, fake Vulkan feature overrides or global guest ICD overrides are installed.

The guest image includes `/usr/bin/steamac-dx12-check`. Run it inside the VM to inspect the **guest-visible** Vulkan version, descriptor-indexing features and limits, shader-draw parameters, mirror-clamp sampling, robustness2 and push descriptors. It exits nonzero if no device passes the conservative baseline. It also reports optional image-view-min-LOD, mutable-descriptor and descriptor-buffer extensions.

Passing that check is necessary diagnostic evidence, not proof that a particular game works. Vulkan conformance alone is insufficient. Validate device creation, shader compilation and a real DX12 game through Venus. No DXR/ray-tracing support is claimed. KosmicKrisp experimental extensions remain opt-in; the build does not enable them globally.

## Controllers

At VM boot, the selected connected GameController profile determines the virtio-input name and IDs:

- DualSense: Sony `054c:0ce6`.
- DualSense Edge when identified by its reported product category: Sony `054c:0df2`.
- DualShock profile: Sony `054c:09cc` (a representative DualShock 4 profile, not USB hardware discovery).
- Other controllers: their reported name and a Steamac virtual ID `1af4:0010`; they are never assigned a fictitious Xbox 360 ID. GameController does not expose arbitrary hardware VID/PID.

Connect the controller **before booting**. The launcher finishes AppKit startup and allows up to two seconds for asynchronous controller discovery before creating the guest device. No guest gamepad is created if none is connected. Virtio-input devices are fixed at boot. A different model attached later is not routed under the previous model's identity; restart the VM. Selecting another controller in Settings marks a restart pending. Reconnecting the same profile is supported.

The bridge covers buttons, sticks, triggers and D-pad. Sony profiles use the joystick layout expected by Steam/SDL for their VID/PID: square/cross/circle/triangle at buttons 0–3, digital triggers at 6–7, analog triggers at axes 3–4, and the right stick at axes 2/5. Generic controllers retain the semantic evdev layout. Axis ranges match their assigned stick or trigger. Regression tests decode the bridge through Steam’s PS5 mapping and check trigger/stick independence. It is **not raw USB/HID passthrough**. Gyro, touchpad, adaptive triggers, rumble, audio and LED output are not implemented. A Bluetooth DualSense was verified locally: Linux exposes Sony `054c:0ce6` with `js0`/evdev, Steam identifies it as a PS5 Controller, and the setup screen shows PlayStation prompts. Rumble and advanced HID features remain unsupported.

## Validation

- `scripts/test/external-storage-check.sh "/Volumes/YourSSD"`: checks real mounted-volume resolution, destination/cache placement, symlinks with spaces, and refusal of internal or disconnected destinations.
- `python3 scripts/test/fork-check.py`: shell syntax, external image defaults and explicit overrides, Docker mount arguments including paths with spaces, missing-volume refusal. No image is created.
- `scripts/test/controller-check.sh`: compiles the production Gamepad bridge with lightweight device/settings stubs and checks real GameController input objects for west/north orientation, generic identity and deadzone behavior.
- `python3 scripts/test/creation-lock-check.py "/Volumes/YourSSD"`: after building the launcher, holds the real creation lock and confirms another creator fails before downloading or writing any image.
- Controller bridge and input device type-checked against libkrun v1.19.6 headers.
- All launcher Swift sources passed syntax parsing.
- DX12 diagnostic compiled against Vulkan SDK 1.4.328.1 headers with warnings treated as errors.
- KosmicKrisp host build completed on Apple M3 / macOS 27.2 with Homebrew LLVM 23.1.2. Both `mesa_clc` shader-generation jobs passed after switching to shared LLVM.
- Rebuilt virglrenderer passed renderer initialization, Venus context/capset creation and host-blob shared-memory export. This smoke test does not exercise a guest Vulkan allocation or rendering.
- The DX12 diagnostic can also be compiled on macOS; run it with this fork's `VK_DRIVER_FILES` manifest. The host Apple M3 driver passed its baseline (Vulkan 1.4.363). Guest-visible capabilities and real game compatibility still require runtime testing.
- MoltenVK default restoration: the rebuilt launcher and signed bundle passed the Venus shared-memory smoke check; the local VM visibly reached the Steam language-selection setup screen. This used the patched MoltenVK library from the original v1.1 release, the rebuilt renderer, and the existing guest layer with persistent 2D launch overrides. Gameplay and DX12 remain unverified.
- Launcher release build, signed app assembly and all eight display formats (CPU PNG and Metal offscreen rendering) passed.
- A direct host Vulkan check passed device creation, external host-memory import, GPU transfer and CPU readback.
- For this launch, the unchanged guest kernel, initramfs, guest layer and libkrun were reused from the official upstream v1.1 DMG; the launcher, virglrenderer and KosmicKrisp were rebuilt. The reused guest layer does not yet include this fork's `steamac-dx12-check` binary.
- Disk creation verified Valve's signed SteamOS stable bundle and began downloading to `/Volumes/Zweidrive/steamac/steamos.img` with its cache on Zweidrive. The 96 GiB home image finished creation, verified its rootfs checksum and booted SteamOS. The original host crashed when the graphical session began. With the native-heap patch, an isolated boot using an APFS clone of that disk reached the graphical session and Steam client startup without that crash. This check used headless mode with networking disabled; a usable Steam login screen, full guest rebuild, guest DualSense recognition and DX12 gameplay remain unverified.

Sources: [Mesa KosmicKrisp](https://docs.mesa3d.org/drivers/kosmickrisp.html), [vkd3d-proton driver requirements](https://github.com/HansKristian-Work/vkd3d-proton#drivers), [Linux PlayStation driver](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-playstation.c).

## Desktop mode

Choose **Switch to Desktop** in Steam to start Plasma, then use **Return to Gaming Mode** on its desktop. The fork replaces the Steam Frame image’s VR-only desktop target with a nested Plasma Wayland session inside Gamescope. It keeps Gamescope alive after its readiness helper exits and continues the launcher’s heartbeat and desktop pointer reporting across the switch. Desktop session controls route to the outer SteamOS session bus so the return shortcut works.

Upgrade the launcher app to `v1.2.1-preview.1` or later and reboot the VM; the existing SteamOS disk and game library are reused. This fix was tested with the current Steam Frame image on the owner’s M3 Mac. Other image revisions need testing.

Desktop mouse input uses the relative Gamescope path in Auto mode. Coordinates are mapped to the nested 1280×800 desktop surface, including the letterboxing Gamescope applies in fullscreen or differently sized windows. This fixes clicks sticking at screen edges. Keep Mouse → Auto selected for the bundled nested desktop; explicit Tablet mode is for a compositor that receives tablet events directly.

## Flatpak app startup

The initramfs binds a synthesized command line over `/proc/cmdline` for SteamOS slot detection. Linux prevents an unprivileged user namespace from mounting procfs when no intact procfs is visible in its parent mount namespace. This caused Chromium and Vesktop to exit during Flatpak sandbox setup.

`run-steamac-proc.mount`, enabled by the guest layer’s multi-user target, supplies a separate intact procfs at `/run/steamac/proc` with `nosuid,nodev,noexec`. Flatpak can mount its sandbox’s procfs without removing SteamOS’s command-line overlay or disabling the sandbox. See [Linux procfs mount restrictions](https://www.kernel.org/doc/html/latest/filesystems/proc.html). Version `v1.2.3-preview.1` includes the persistent fix.
