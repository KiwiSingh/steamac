// Guest-side end-to-end check of the Venus scanout path gamescope's DRM backend uses:
//   1. LINEAR must be offered as a DRM format modifier with SAMPLED | STORAGE | TRANSFER_SRC
//      for the 8888 / 2101010 formats (gamescope pick_plane_format);
//   2. a DRM_FORMAT_MODIFIER_EXT image (modifier list {LINEAR}) with gamescope's scanout
//      usage, on dedicated memory exported as a dma-buf, filled by the GPU from a gradient
//      (vkCmdCopyBufferToImage, so any row-pitch mismatch shows);
//   3. the dma-buf imported into KMS (AddFB2 with the image's modifier, offset and pitch)
//      and set as the CRTC's framebuffer -> virtio-gpu SET_SCANOUT_BLOB + RESOURCE_FLUSH.
// The host side then dumps the presented frame (steamac-vm SIGUSR1) and compares it with
// the gradient (see guest_scanout_expect.py). Run as root with no other DRM master.
//
// Build (arm64 Linux): cc -O2 -o guest_scanout guest_scanout.c -lvulkan -ldrm -I/usr/include/libdrm
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <vulkan/vulkan.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

#define CHECK(x)                                                                                   \
    do {                                                                                           \
        VkResult r_ = (x);                                                                         \
        if (r_ != VK_SUCCESS) {                                                                    \
            fprintf(stderr, "%s:%d %s -> %d\n", __FILE__, __LINE__, #x, r_);                      \
            exit(1);                                                                               \
        }                                                                                          \
    } while (0)

static int failures;

static uint32_t pick_memory(VkPhysicalDevice pd, uint32_t bits, VkMemoryPropertyFlags want)
{
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
            return i;
    fprintf(stderr, "no memory type for bits 0x%x flags 0x%x\n", bits, want);
    exit(1);
}

static void check_modifiers(VkPhysicalDevice pd, VkFormat fmt, const char *name)
{
    const VkFormatFeatureFlags need = VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
                                      VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT |
                                      VK_FORMAT_FEATURE_TRANSFER_SRC_BIT;
    VkDrmFormatModifierPropertiesEXT mods[8];
    VkDrmFormatModifierPropertiesListEXT ml = {
        .sType = VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT,
        .drmFormatModifierCount = 8,
        .pDrmFormatModifierProperties = mods,
    };
    VkFormatProperties2 fp = { .sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2, .pNext = &ml };
    vkGetPhysicalDeviceFormatProperties2(pd, fmt, &fp);

    VkDrmFormatModifierProperties2EXT mods2[8];
    VkDrmFormatModifierPropertiesList2EXT ml2 = {
        .sType = VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_2_EXT,
        .drmFormatModifierCount = 8,
        .pDrmFormatModifierProperties = mods2,
    };
    VkFormatProperties2 fp2 = { .sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2, .pNext = &ml2 };
    vkGetPhysicalDeviceFormatProperties2(pd, fmt, &fp2);

    int ok = 0;
    for (uint32_t i = 0; i < ml.drmFormatModifierCount; i++)
        if (mods[i].drmFormatModifier == DRM_FORMAT_MOD_LINEAR &&
            (mods[i].drmFormatModifierTilingFeatures & need) == need)
            ok = 1;
    int ok2 = 0;
    for (uint32_t i = 0; i < ml2.drmFormatModifierCount; i++)
        if (mods2[i].drmFormatModifier == DRM_FORMAT_MOD_LINEAR &&
            (mods2[i].drmFormatModifierTilingFeatures & need) == need)
            ok2 = 1;
    printf("%-26s linear=0x%08x mods=%u LINEAR features=0x%08x list2=0x%08llx %s\n", name,
           fp.formatProperties.linearTilingFeatures, ml.drmFormatModifierCount,
           ml.drmFormatModifierCount ? mods[0].drmFormatModifierTilingFeatures : 0,
           ml2.drmFormatModifierCount
               ? (unsigned long long)mods2[0].drmFormatModifierTilingFeatures
               : 0ull,
           ok && ok2 ? "OK" : "FAIL");
    if (!(ok && ok2))
        failures++;
}

int main(int argc, char **argv)
{
    const uint32_t W = argc > 2 ? (uint32_t)atoi(argv[1]) : 1280;
    const uint32_t H = argc > 2 ? (uint32_t)atoi(argv[2]) : 800;
    const VkFormat fmt = VK_FORMAT_B8G8R8A8_UNORM; // DRM_FORMAT_ARGB8888 / XRGB8888

    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                              .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                                 .pApplicationInfo = &app };
    VkInstance inst;
    CHECK(vkCreateInstance(&ici, NULL, &inst));
    uint32_t n = 1;
    VkPhysicalDevice pd;
    vkEnumeratePhysicalDevices(inst, &n, &pd);

    check_modifiers(pd, VK_FORMAT_B8G8R8A8_UNORM, "B8G8R8A8_UNORM");
    check_modifiers(pd, VK_FORMAT_R8G8B8A8_UNORM, "R8G8B8A8_UNORM");
    check_modifiers(pd, VK_FORMAT_A2R10G10B10_UNORM_PACK32, "A2R10G10B10_UNORM_PACK32");
    check_modifiers(pd, VK_FORMAT_A2B10G10R10_UNORM_PACK32, "A2B10G10R10_UNORM_PACK32");

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                    .queueCount = 1, .pQueuePriorities = &prio };
    const char *exts[] = { VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
                           VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
                           VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME };
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                               .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
                               .enabledExtensionCount = 3, .ppEnabledExtensionNames = exts };
    VkDevice dev;
    CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
    VkQueue q;
    vkGetDeviceQueue(dev, 0, 0, &q);

    // --- gamescope-style scanout image
    const uint64_t linear = DRM_FORMAT_MOD_LINEAR;
    VkImageDrmFormatModifierListCreateInfoEXT modlist = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
        .drmFormatModifierCount = 1, .pDrmFormatModifiers = &linear };
    VkExternalMemoryImageCreateInfo emi = {
        .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO, .pNext = &modlist,
        .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT };
    VkImageCreateInfo ii = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = &emi,
        .imageType = VK_IMAGE_TYPE_2D, .format = fmt, .extent = { W, H, 1 },
        .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                 VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
                 VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
    VkImage img;
    CHECK(vkCreateImage(dev, &ii, NULL, &img));

    VkMemoryRequirements mr;
    vkGetImageMemoryRequirements(dev, img, &mr);
    VkMemoryDedicatedAllocateInfo ded = { .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
                                          .image = img };
    VkExportMemoryAllocateInfo exp = { .sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
                                       .pNext = &ded,
                                       .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT };
    VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = &exp,
                                 .allocationSize = mr.size,
                                 .memoryTypeIndex = pick_memory(pd, mr.memoryTypeBits, 0) };
    VkDeviceMemory mem;
    CHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
    CHECK(vkBindImageMemory(dev, img, mem, 0));

    PFN_vkGetImageDrmFormatModifierPropertiesEXT getmod =
        (PFN_vkGetImageDrmFormatModifierPropertiesEXT)vkGetDeviceProcAddr(
            dev, "vkGetImageDrmFormatModifierPropertiesEXT");
    VkImageDrmFormatModifierPropertiesEXT modp = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT };
    CHECK(getmod(dev, img, &modp));
    VkImageSubresource sub = { .aspectMask = VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT };
    VkSubresourceLayout lay;
    vkGetImageSubresourceLayout(dev, img, &sub, &lay);
    printf("scanout image %ux%u modifier 0x%llx offset %llu rowPitch %llu size %llu (mem %llu)\n",
           W, H, (unsigned long long)modp.drmFormatModifier, (unsigned long long)lay.offset,
           (unsigned long long)lay.rowPitch, (unsigned long long)lay.size,
           (unsigned long long)mr.size);

    PFN_vkGetMemoryFdKHR getfd = (PFN_vkGetMemoryFdKHR)vkGetDeviceProcAddr(dev, "vkGetMemoryFdKHR");
    VkMemoryGetFdInfoKHR gfi = { .sType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR, .memory = mem,
                                 .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT };
    int dmabuf;
    CHECK(getfd(dev, &gfi, &dmabuf));

    // --- gradient: B = x, G = y, R = (x ^ y), A = 0xff, uploaded by the GPU
    const VkDeviceSize bufsize = (VkDeviceSize)W * H * 4;
    VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = bufsize,
                               .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT };
    VkBuffer buf;
    CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));
    VkMemoryRequirements bmr;
    vkGetBufferMemoryRequirements(dev, buf, &bmr);
    VkMemoryAllocateInfo bmai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = bmr.size,
        .memoryTypeIndex = pick_memory(pd, bmr.memoryTypeBits,
                                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                           VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
    VkDeviceMemory bmem;
    CHECK(vkAllocateMemory(dev, &bmai, NULL, &bmem));
    CHECK(vkBindBufferMemory(dev, buf, bmem, 0));
    uint8_t *p;
    CHECK(vkMapMemory(dev, bmem, 0, bufsize, 0, (void **)&p));
    for (uint32_t y = 0; y < H; y++)
        for (uint32_t x = 0; x < W; x++) {
            uint8_t *px = p + ((size_t)y * W + x) * 4;
            px[0] = (uint8_t)x;
            px[1] = (uint8_t)y;
            px[2] = (uint8_t)(x ^ y);
            px[3] = 0xff;
        }
    vkUnmapMemory(dev, bmem);

    VkCommandPoolCreateInfo cpci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    VkCommandPool pool;
    CHECK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
    VkCommandBufferAllocateInfo cbai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                         .commandPool = pool,
                                         .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                                         .commandBufferCount = 1 };
    VkCommandBuffer cb;
    CHECK(vkAllocateCommandBuffers(dev, &cbai, &cb));
    VkCommandBufferBeginInfo cbbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    CHECK(vkBeginCommandBuffer(cb, &cbbi));
    VkImageMemoryBarrier to_dst = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = img, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0,
                         NULL, 0, NULL, 1, &to_dst);
    VkBufferImageCopy region = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                                 .imageExtent = { W, H, 1 } };
    vkCmdCopyBufferToImage(cb, buf, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    VkImageMemoryBarrier to_ext = to_dst;
    to_ext.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    to_ext.dstAccessMask = 0;
    to_ext.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    to_ext.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    to_ext.srcQueueFamilyIndex = 0;
    to_ext.dstQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT;
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0,
                         0, NULL, 0, NULL, 1, &to_ext);
    CHECK(vkEndCommandBuffer(cb));
    VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1,
                        .pCommandBuffers = &cb };
    CHECK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
    CHECK(vkQueueWaitIdle(q));

    // --- KMS: import and scan out
    int card = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (card < 0 || drmSetMaster(card)) {
        fprintf(stderr, "cannot become DRM master on card0: %s\n", strerror(errno));
        return 1;
    }
    drmSetClientCap(card, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
    uint32_t handle;
    if (drmPrimeFDToHandle(card, dmabuf, &handle)) {
        fprintf(stderr, "drmPrimeFDToHandle: %s\n", strerror(errno));
        return 1;
    }
    uint32_t handles[4] = { handle }, pitches[4] = { (uint32_t)lay.rowPitch },
             offsets[4] = { (uint32_t)lay.offset };
    uint64_t modifiers[4] = { modp.drmFormatModifier };
    uint64_t has_modifiers = 0;
    drmGetCap(card, DRM_CAP_ADDFB2_MODIFIERS, &has_modifiers);
    uint32_t fb;
    // virtio-gpu KMS takes no modifiers: an FB without one is linear, which is what
    // gamescope's DRM backend does there too.
    int ret = has_modifiers
                  ? drmModeAddFB2WithModifiers(card, W, H, DRM_FORMAT_XRGB8888, handles, pitches,
                                               offsets, modifiers, &fb, DRM_MODE_FB_MODIFIERS)
                  : drmModeAddFB2(card, W, H, DRM_FORMAT_XRGB8888, handles, pitches, offsets, &fb,
                                  0);
    if (ret) {
        fprintf(stderr, "AddFB2 (modifiers cap %llu): %s\n", (unsigned long long)has_modifiers,
                strerror(errno));
        return 1;
    }
    drmModeRes *res = drmModeGetResources(card);
    drmModeConnector *conn = drmModeGetConnector(card, res->connectors[0]);
    drmModeModeInfo mode = conn->modes[0];
    for (int i = 0; i < conn->count_modes; i++)
        if (conn->modes[i].hdisplay == W && conn->modes[i].vdisplay == H) {
            mode = conn->modes[i];
            break;
        }
    if (drmModeSetCrtc(card, res->crtcs[0], fb, 0, 0, &conn->connector_id, 1, &mode)) {
        fprintf(stderr, "SetCrtc: %s\n", strerror(errno));
        return 1;
    }
    // Some drivers only flush on damage: report the whole framebuffer dirty too.
    drmModeClip clip = { 0, 0, (uint16_t)W, (uint16_t)H };
    drmModeDirtyFB(card, fb, &clip, 1);
    printf("scanned out fb %u (%ux%u, mode %ux%u); %s\n", fb, W, H, mode.hdisplay, mode.vdisplay,
           failures ? "modifier checks FAILED" : "modifier checks OK");
    fflush(stdout);
    // Keep the framebuffer on screen until the host has dumped it.
    sleep(argc > 3 ? atoi(argv[3]) : 20);
    return failures ? 1 : 0;
}
