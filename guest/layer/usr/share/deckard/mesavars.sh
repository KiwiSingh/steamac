# steamac: replaces the Frame's /usr/share/deckard/mesavars.sh
# (EnvironmentFile of gamescope-session.service and steam.service).
# The VM has no Adreno: Vulkan is Mesa Venus (libvulkan_virtio.so, added by the
# steamac layer from guest/mesa) over virtio-gpu to the host's selected Vulkan driver, and GL
# is the stock zink_dri.so on top of that Vulkan device. Values from guest/mesa.
#
# Dropped from stock: VRCOMPOSITOR_TU_DEBUG (Turnip-only, for the SteamVR
# compositor, which is masked in the VM). No VK_ICD_FILENAMES/VK_DRIVER_FILES:
# Turnip finds no kgsl/msm device and is skipped, and a global value would leak
# into pressure-vessel/FEX where the aarch64 JSON is wrong.

# MoltenVK has no geometryShader, so zink natively reports ~GL 3.1; the
# override lets GL 3.3/4.x applications create contexts (same as stock).
MESA_GL_VERSION_OVERRIDE=4.3
MESA_GLSL_VERSION_OVERRIDE=430

# GL through zink (the Frame image ships no virgl/virtio_gpu GL driver)
MESA_LOADER_DRIVER_OVERRIDE=zink
