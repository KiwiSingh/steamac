# External SSD / KosmicKrisp fork

This fork changes the default storage and Vulkan implementation. The remaining upstream README describes the original MoltenVK release; its game compatibility results do not validate this fork.

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

The rendering path is:
`Proton vkd3d-proton → guest Vulkan/Venus → virglrenderer → Vulkan loader → KosmicKrisp → Metal 4`.

The host now links the Vulkan **loader**, because Mesa exposes the ICD interface rather than MoltenVK's directly linked Vulkan API. The launcher pins `VK_DRIVER_FILES` to its own KosmicKrisp manifest before renderer initialization. Bundles contain the loader, ICD, a relative-path manifest, and recursively copied non-system dynamic dependencies. The existing Venus renderer/shared-memory smoke test runs with this ICD selected.

Build prerequisites (the new driver script checks them and does not install them silently):
`meson ninja pkgconf llvm libclc spirv-llvm-translator spirv-tools vulkan-loader vulkan-headers`.
The remaining host builds also need `dtc xz lld libepoxy`, rustup and their existing prerequisites. Guest builds require a running Docker/OrbStack engine with privileged arm64 containers.

Build with `./build.sh`; individual host driver builds use `host/kosmickrisp/build.sh`. The Homebrew build uses shared LLVM, matching the SPIR-V translator. Mixing statically linked LLVM in `mesa_clc` with the translator's shared LLVM duplicates analysis state and crashes shader generation. Shared LLVM is a build-tool dependency, not a runtime dependency of the KosmicKrisp ICD.

Steam's ARM-compatible Proton supplies vkd3d-proton and DXVK's shared DXGI. Select the compatible Proton version for the game in Steam. No macOS Wine DLLs, fake Vulkan feature overrides or global guest ICD overrides are installed.

The guest image includes `/usr/bin/steamac-dx12-check`. Run it inside the VM to inspect the **guest-visible** Vulkan version, descriptor-indexing features and limits, shader-draw parameters, mirror-clamp sampling, robustness2 and push descriptors. It exits nonzero if no device passes the conservative baseline. It also reports optional image-view-min-LOD, mutable-descriptor and descriptor-buffer extensions.

Passing that check is necessary diagnostic evidence, not proof that a particular game works. Vulkan conformance alone is insufficient. Validate device creation, shader compilation and a real DX12 game through Venus. No DXR/ray-tracing support is claimed. KosmicKrisp experimental extensions remain opt-in; the build does not enable them globally.

## Controllers

At VM boot, the selected connected GameController profile determines the virtio-input name and IDs:

- DualSense: Sony `054c:0ce6`.
- DualSense Edge when identified by its reported product category: Sony `054c:0df2`.
- DualShock profile: Sony `054c:09cc` (a representative DualShock 4 profile, not USB hardware discovery).
- Other controllers: their reported name and a Steamac virtual ID `1af4:0010`; they are never assigned a fictitious Xbox 360 ID. GameController does not expose arbitrary hardware VID/PID.

Connect the controller **before booting**. No guest gamepad is created if none is connected. Virtio-input devices are fixed at boot. A different model attached later is not routed under the previous model's identity; restart the VM. Selecting another controller in Settings marks a restart pending. Reconnecting the same profile is supported.

The bridge covers buttons, sticks, triggers and D-pad with standard Linux button positions (square/X is west, triangle/Y is north). It is **not raw USB/HID passthrough**. Gyro, touchpad, adaptive triggers, rumble, audio and LED output are not implemented. Guest Steam/SDL recognition still needs a real-controller runtime check.

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
- Launcher release build, signed app assembly and all eight display formats (CPU PNG and Metal offscreen rendering) passed.
- A direct host Vulkan check passed device creation, external host-memory import, GPU transfer and CPU readback.
- For this launch, the unchanged guest kernel, initramfs, guest layer and libkrun were reused from the official upstream v1.1 DMG; the launcher, virglrenderer and KosmicKrisp were rebuilt. The reused guest layer does not yet include this fork's `steamac-dx12-check` binary.
- Disk creation verified Valve's signed SteamOS stable bundle and began downloading to `/Volumes/Zweidrive/steamac/steamos.img` with its cache on Zweidrive. Final disk writing, full guest rebuild, guest DualSense recognition and DX12 gameplay remain unverified.

Sources: [Mesa KosmicKrisp](https://docs.mesa3d.org/drivers/kosmickrisp.html), [vkd3d-proton driver requirements](https://github.com/HansKristian-Work/vkd3d-proton#drivers), [Linux PlayStation driver](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-playstation.c).
