# Zweidrive / KosmicKrisp fork

This fork changes the default storage and Vulkan implementation. The remaining upstream README describes the original MoltenVK release; its game compatibility results do not validate this fork.

## Storage

The default VM disk is `/Volumes/Zweidrive/steamac/steamos.img`. It is a sparse GPT image **file**, not a write to the physical drive. Existing files are preserved unless the existing explicit `FORCE_DISK=1` rebuild option is used.

The GUI creates its temporary rootfs, partial image and provisioning payload beside the image. Download caches are in `/Volumes/Zweidrive/steamac/cache`. Missing Zweidrive never falls back to an internal default. Scripts verify that the path is a mounted volume, not a leftover directory on the internal SSD.

`./run.sh` uses the external image; `STEAMAC_DISK_PATH` is an explicit override. Docker builds mount `/Volumes/Zweidrive/steamac` as `/disk` for both creation and verification; `STEAMAC_DISK_DIR` is an explicit directory override. GUI Settings can still select an existing image explicitly.

Keep the checkout and its work directory on Zweidrive too. The top-level build places temporary files, Python caches, Rust toolchains and Cargo downloads beside the checkout. The Swift package cache also lives there. Homebrew and Docker manage their own storage separately: verify their available space before installing packages or starting Docker.

## Vulkan / DirectX 12

Requires Apple Silicon, macOS 26+ and full Xcode 26+. KosmicKrisp is built from Mesa commit `4cf0989083d25b92d02c6fef2bed934ad77b4ecd`, the same Mesa revision as the guest Venus build.

The rendering path is:
`Proton vkd3d-proton → guest Vulkan/Venus → virglrenderer → Vulkan loader → KosmicKrisp → Metal 4`.

The host now links the Vulkan **loader**, because Mesa exposes the ICD interface rather than MoltenVK's directly linked Vulkan API. The launcher pins `VK_DRIVER_FILES` to its own KosmicKrisp manifest before renderer initialization. Bundles contain the loader, ICD, a relative-path manifest, and recursively copied non-system dynamic dependencies. The existing Venus renderer/shared-memory smoke test runs with this ICD selected.

Build prerequisites (the new driver script checks them and does not install them silently):
`meson ninja pkgconf llvm libclc spirv-llvm-translator spirv-tools vulkan-loader vulkan-headers`.
The remaining host builds also need `dtc xz lld libepoxy`, rustup and their existing prerequisites. Guest builds require a running Docker/OrbStack engine with privileged arm64 containers.

Build with `./build.sh`; individual host driver builds use `host/kosmickrisp/build.sh`.

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

- `python3 scripts/test/fork-check.py`: shell syntax, external image defaults and explicit overrides, Docker mount arguments including paths with spaces, missing-volume refusal. No image is created.
- `scripts/test/controller-check.sh`: compiles the production Gamepad bridge with lightweight device/settings stubs and checks real GameController input objects for west/north orientation, generic identity and deadzone behavior.
- Controller bridge and input device type-checked against libkrun v1.19.6 headers.
- All launcher Swift sources passed syntax parsing.
- DX12 diagnostic compiled against Vulkan SDK 1.4.328.1 headers with warnings treated as errors.
- Full host/guest build, Venus shared-memory runtime test, disk creation, guest DualSense recognition and DX12 gameplay remain unverified. On the development machine the internal SSD is full, Meson and other host dependencies are missing, and Docker is not running.

Sources: [Mesa KosmicKrisp](https://docs.mesa3d.org/drivers/kosmickrisp.html), [vkd3d-proton driver requirements](https://github.com/HansKristian-Work/vkd3d-proton#drivers), [Linux PlayStation driver](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-playstation.c).
