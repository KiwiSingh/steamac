// Guest-side check that object creations the host fails never kill the Venus context.
//
// Venus creates most objects asynchronously: the guest has a handle before the host has
// created anything, and a host failure only shows on the host (virglrenderer logs it).
// Each test makes the host fail creations and then uses, binds and destroys the failed
// objects the way applications and the Venus driver do; a context the host declared fatal
// aborts the process (Mesa: "vn_ring_submit abort on fatal"), so every test ends with a
// queue round trip and prints "<test>: ALIVE" only if the context survived.
//
//   pipe-async    vkCreate{Graphics,Compute}Pipelines on the primary ring (this thread owns a
//                 command pool, so Venus creates pipelines asynchronously): calls mixing good
//                 and failing pipelines, a derivative of a failed pipeline, draws/dispatches
//                 with the failed pipelines bound, destroy
//   pipe-threads  the same from worker threads (synchronous on per-thread rings, as DXVK's
//                 compiler threads do), several rounds of short-lived threads
//   pipe-flags    FAIL_ON_PIPELINE_COMPILE_REQUIRED and EARLY_RETURN_ON_FAILURE
//   pipe-cache    failing pipelines with a VkPipelineCache, cache data read back
//   mem-export    a 4 KiB dma_buf-exportable allocation on every memory type (mangoapp's
//                 overlay buffer), freed again
//   mem-huge      allocations the host cannot satisfy (async), with and without export, freed
//   image-buffer  images/buffers the host refuses (oversized), destroyed
//   fatal-attribution  (only when named; kills the context on purpose) worker threads keep
//                 their rings busy creating pipelines while this thread binds VK_NULL_HANDLE:
//                 the host must log the CS error for that command only, the busy rings
//                 "... stopped: the context went fatal on another thread"
//
// Host failure triggers: a fragment shader doing double-precision math (Metal has no double:
// the MSL does not compile) and a compute workgroup of 2048 invocations (Metal's limit is 1024).
//
// Build (arm64 Linux): host/virglrenderer/test/build-guest-failures.sh
// Run: guest_failures [TEST...]   (default: all but fatal-attribution, in this process)
#define _GNU_SOURCE
#include <stdbool.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>

#include "guest_failures_spv.h"

#define CHECK(x)                                                                                   \
    do {                                                                                           \
        VkResult r_ = (x);                                                                         \
        if (r_ != VK_SUCCESS) {                                                                    \
            fprintf(stderr, "%s:%d %s -> %d\n", __FILE__, __LINE__, #x, r_);                      \
            exit(1);                                                                               \
        }                                                                                          \
    } while (0)

static VkInstance instance;
static VkPhysicalDevice pdev;
static VkDevice dev;
static VkQueue queue;
static uint32_t queue_family;
static VkCommandPool cmd_pool;
static VkPipelineLayout layout;
static VkShaderModule vs, fs, fs_bad, cs;
static VkImage color_image;
static VkImageView color_view;
static VkDeviceMemory color_mem;

static uint32_t pick_memory(uint32_t bits, VkMemoryPropertyFlags want)
{
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pdev, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
            return i;
    fprintf(stderr, "no memory type for bits 0x%x flags 0x%x\n", bits, want);
    exit(1);
}

static VkShaderModule make_module(const uint32_t *code, size_t size)
{
    VkShaderModuleCreateInfo ci = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = size,
        .pCode = code,
    };
    VkShaderModule m;
    CHECK(vkCreateShaderModule(dev, &ci, NULL, &m));
    return m;
}

static void init(void)
{
    VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "guest_failures",
        .apiVersion = VK_API_VERSION_1_3,
    };
    VkInstanceCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
    };
    CHECK(vkCreateInstance(&ici, NULL, &instance));
    uint32_t n = 1;
    VkResult r = vkEnumeratePhysicalDevices(instance, &n, &pdev);
    if ((r != VK_SUCCESS && r != VK_INCOMPLETE) || !n) {
        fprintf(stderr, "no physical device\n");
        exit(1);
    }
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pdev, &props);
    printf("device: %s, api %u.%u, maxComputeWorkGroupInvocations %u, "
           "framebufferColorSampleCounts 0x%x\n",
           props.deviceName, VK_API_VERSION_MAJOR(props.apiVersion),
           VK_API_VERSION_MINOR(props.apiVersion), props.limits.maxComputeWorkGroupInvocations,
           props.limits.framebufferColorSampleCounts);

    uint32_t qn = 8;
    VkQueueFamilyProperties qf[8];
    vkGetPhysicalDeviceQueueFamilyProperties(pdev, &qn, qf);
    for (queue_family = 0; queue_family < qn; queue_family++)
        if (qf[queue_family].queueFlags & VK_QUEUE_GRAPHICS_BIT)
            break;

    const float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = queue_family,
        .queueCount = 1,
        .pQueuePriorities = &prio,
    };
    const char *exts[] = {
        VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
        VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
    };
    VkPhysicalDeviceVulkan13Features f13 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .pipelineCreationCacheControl = VK_TRUE,
        .dynamicRendering = VK_TRUE,
    };
    VkDeviceCreateInfo dci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &f13,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qci,
        .enabledExtensionCount = 2,
        .ppEnabledExtensionNames = exts,
    };
    CHECK(vkCreateDevice(pdev, &dci, NULL, &dev));
    vkGetDeviceQueue(dev, queue_family, 0, &queue);

    // A command pool on this thread makes Venus create pipelines asynchronously here.
    VkCommandPoolCreateInfo cpci = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = queue_family,
    };
    CHECK(vkCreateCommandPool(dev, &cpci, NULL, &cmd_pool));

    const VkPushConstantRange push = { VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(float) };
    VkPipelineLayoutCreateInfo plci = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push,
    };
    CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
    vs = make_module(guest_failures_vert, sizeof(guest_failures_vert));
    fs = make_module(guest_failures_frag, sizeof(guest_failures_frag));
    fs_bad = make_module(guest_failures_frag_bad, sizeof(guest_failures_frag_bad));
    cs = make_module(guest_failures_comp, sizeof(guest_failures_comp));

    VkImageCreateInfo ici2 = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = { 64, 64, 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
    };
    CHECK(vkCreateImage(dev, &ici2, NULL, &color_image));
    VkMemoryRequirements mr;
    vkGetImageMemoryRequirements(dev, color_image, &mr);
    VkMemoryAllocateInfo mai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mr.size,
        .memoryTypeIndex = pick_memory(mr.memoryTypeBits, 0),
    };
    CHECK(vkAllocateMemory(dev, &mai, NULL, &color_mem));
    CHECK(vkBindImageMemory(dev, color_image, color_mem, 0));
    VkImageViewCreateInfo vci = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = color_image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    CHECK(vkCreateImageView(dev, &vci, NULL, &color_view));
}

// A queue round trip: aborts in the Venus driver if the host killed the context.
static void probe(const char *test)
{
    VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence;
    CHECK(vkCreateFence(dev, &fci, NULL, &fence));
    VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO };
    CHECK(vkQueueSubmit(queue, 1, &si, fence));
    VkResult r = vkWaitForFences(dev, 1, &fence, VK_TRUE, 5000000000ull);
    vkDestroyFence(dev, fence, NULL);
    CHECK(vkDeviceWaitIdle(dev));
    printf("%s: %s\n", test, r == VK_SUCCESS ? "ALIVE" : "DEAD (fence timeout)");
    fflush(stdout);
    if (r != VK_SUCCESS)
        exit(2);
}

// --- pipelines

struct gfx_desc {
    VkGraphicsPipelineCreateInfo ci;
    VkPipelineShaderStageCreateInfo stages[2];
    VkPipelineMultisampleStateCreateInfo ms;
    VkPipelineRenderingCreateInfo rendering;
    VkFormat format;
};

static const VkPipelineVertexInputStateCreateInfo vi = {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
};
static const VkPipelineInputAssemblyStateCreateInfo ia = {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
};
static const VkViewport viewport = { 0, 0, 64, 64, 0, 1 };
static const VkRect2D scissor = { { 0, 0 }, { 64, 64 } };
static const VkPipelineViewportStateCreateInfo vp = {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    .viewportCount = 1,
    .pViewports = &viewport,
    .scissorCount = 1,
    .pScissors = &scissor,
};
static const VkPipelineRasterizationStateCreateInfo rs = {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    .polygonMode = VK_POLYGON_MODE_FILL,
    .cullMode = VK_CULL_MODE_NONE,
    .lineWidth = 1.0f,
};
static const VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
static const VkPipelineColorBlendStateCreateInfo cb = {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    .attachmentCount = 1,
    .pAttachments = &cba,
};

// fail: a fragment shader whose MSL the host's Metal compiler rejects (double math)
static void gfx_desc_init(struct gfx_desc *d, bool fail, VkPipelineCreateFlags flags)
{
    memset(d, 0, sizeof(*d));
    d->format = VK_FORMAT_R8G8B8A8_UNORM;
    d->stages[0] = (VkPipelineShaderStageCreateInfo){
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_VERTEX_BIT,
        .module = vs,
        .pName = "main",
    };
    d->stages[1] = (VkPipelineShaderStageCreateInfo){
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = fail ? fs_bad : fs,
        .pName = "main",
    };
    d->ms = (VkPipelineMultisampleStateCreateInfo){
        .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
    };
    d->rendering = (VkPipelineRenderingCreateInfo){
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &d->format,
    };
    d->ci = (VkGraphicsPipelineCreateInfo){
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = &d->rendering,
        .flags = flags,
        .stageCount = 2,
        .pStages = d->stages,
        .pVertexInputState = &vi,
        .pInputAssemblyState = &ia,
        .pViewportState = &vp,
        .pRasterizationState = &rs,
        .pMultisampleState = &d->ms,
        .pColorBlendState = &cb,
        .layout = layout,
        .basePipelineIndex = -1,
    };
}

static VkResult create_gfx(VkPipelineCache cache, uint32_t count, const bool *fail,
                           VkPipelineCreateFlags flags, VkPipeline *out)
{
    struct gfx_desc d[8];
    VkGraphicsPipelineCreateInfo ci[8];
    for (uint32_t i = 0; i < count; i++) {
        gfx_desc_init(&d[i], fail[i], flags);
        ci[i] = d[i].ci;
    }
    return vkCreateGraphicsPipelines(dev, cache, count, ci, NULL, out);
}

static const VkSpecializationMapEntry wg_entry = { 0, 0, sizeof(uint32_t) };

// fail: a 2048-invocation workgroup, over Metal's 1024 limit
static VkResult create_compute(VkPipelineCache cache, uint32_t count, const bool *fail,
                               VkPipelineCreateFlags flags, VkPipeline *out)
{
    static const uint32_t wg_ok = 64, wg_fail = 2048;
    VkSpecializationInfo spec[8];
    VkComputePipelineCreateInfo ci[8];
    for (uint32_t i = 0; i < count; i++) {
        spec[i] = (VkSpecializationInfo){
            .mapEntryCount = 1,
            .pMapEntries = &wg_entry,
            .dataSize = sizeof(uint32_t),
            .pData = fail[i] ? &wg_fail : &wg_ok,
        };
        ci[i] = (VkComputePipelineCreateInfo){
            .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .flags = flags,
            .stage = {
                .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = VK_SHADER_STAGE_COMPUTE_BIT,
                .module = cs,
                .pName = "main",
                .pSpecializationInfo = &spec[i],
            },
            .layout = layout,
            .basePipelineIndex = -1,
        };
    }
    return vkCreateComputePipelines(dev, cache, count, ci, NULL, out);
}

static void destroy_pipelines(uint32_t count, VkPipeline *p)
{
    for (uint32_t i = 0; i < count; i++)
        vkDestroyPipeline(dev, p[i], NULL);
}

// Draw with each graphics pipeline and dispatch with each compute pipeline, then wait.
static void use_pipelines(uint32_t gcount, const VkPipeline *g, uint32_t ccount,
                          const VkPipeline *c)
{
    VkCommandBufferAllocateInfo ai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = cmd_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer cmd;
    CHECK(vkAllocateCommandBuffers(dev, &ai, &cmd));
    VkCommandBufferBeginInfo bi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    CHECK(vkBeginCommandBuffer(cmd, &bi));
    VkImageMemoryBarrier barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = color_image,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL, 0, NULL, 1,
                         &barrier);
    VkRenderingAttachmentInfo att = {
        .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = color_view,
        .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
    };
    VkRenderingInfo ri = {
        .sType = VK_STRUCTURE_TYPE_RENDERING_INFO,
        .renderArea = scissor,
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &att,
    };
    vkCmdBeginRendering(cmd, &ri);
    for (uint32_t i = 0; i < gcount; i++) {
        if (!g[i])
            continue;
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, g[i]);
        vkCmdDraw(cmd, 3, 1, 0, 0);
    }
    vkCmdEndRendering(cmd);
    for (uint32_t i = 0; i < ccount; i++) {
        if (!c[i])
            continue;
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, c[i]);
        vkCmdDispatch(cmd, 1, 1, 1);
    }
    CHECK(vkEndCommandBuffer(cmd));
    VkSubmitInfo si = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
    };
    CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
    CHECK(vkQueueWaitIdle(queue));
    vkFreeCommandBuffers(dev, cmd_pool, 1, &cmd);
}

static void test_pipe_async(void)
{
    const bool mixed[3] = { false, true, false };
    VkPipeline g[4] = { 0 }, c[3] = { 0 };

    VkResult r = create_gfx(VK_NULL_HANDLE, 3, mixed, VK_PIPELINE_CREATE_ALLOW_DERIVATIVES_BIT, g);
    printf("  graphics [ok, fail, ok]: %d (async: the guest sees success)\n", r);

    // derivative of the failed pipeline
    struct gfx_desc d;
    gfx_desc_init(&d, false, VK_PIPELINE_CREATE_DERIVATIVE_BIT);
    d.ci.basePipelineHandle = g[1];
    r = vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &d.ci, NULL, &g[3]);
    printf("  graphics derivative of the failed one: %d\n", r);

    const bool one_fail[1] = { true };
    VkPipeline single;
    r = create_gfx(VK_NULL_HANDLE, 1, one_fail, 0, &single);
    printf("  graphics [fail]: %d\n", r);

    r = create_compute(VK_NULL_HANDLE, 3, mixed, 0, c);
    printf("  compute [ok, fail, ok]: %d\n", r);

    use_pipelines(4, g, 3, c);
    use_pipelines(1, &single, 0, NULL);
    destroy_pipelines(4, g);
    destroy_pipelines(3, c);
    destroy_pipelines(1, &single);
}

struct worker {
    pthread_t thread;
    int index;
    int failed, created;
};

static void *pipe_worker(void *arg)
{
    struct worker *w = arg;
    for (int i = 0; i < 6; i++) {
        const bool fail[2] = { (i + w->index) % 2 == 0, (i + w->index) % 3 == 0 };
        VkPipeline p[2] = { 0 };
        VkResult r = (i % 3 == 2) ? create_compute(VK_NULL_HANDLE, 2, fail, 0, p)
                                  : create_gfx(VK_NULL_HANDLE, 2, fail, 0, p);
        if (r != VK_SUCCESS)
            w->failed++;
        for (int j = 0; j < 2; j++)
            if (p[j])
                w->created++;
        destroy_pipelines(2, p);
    }
    return NULL;
}

static void test_pipe_threads(void)
{
    for (int round = 0; round < 3; round++) {
        struct worker w[6] = { 0 };
        for (int i = 0; i < 6; i++) {
            w[i].index = i;
            pthread_create(&w[i].thread, NULL, pipe_worker, &w[i]);
        }
        int failed = 0, created = 0;
        for (int i = 0; i < 6; i++) {
            pthread_join(w[i].thread, NULL);
            failed += w[i].failed;
            created += w[i].created;
        }
        printf("  round %d: 36 calls on worker threads, %d failed, %d pipelines created\n", round,
               failed, created);
    }
}

static void test_pipe_flags(void)
{
    const bool fail1[1] = { true };
    const bool fok[3] = { true, false, false };
    VkPipeline p[3] = { 0 };

    VkResult r = create_gfx(VK_NULL_HANDLE, 1, fail1,
                            VK_PIPELINE_CREATE_FAIL_ON_PIPELINE_COMPILE_REQUIRED_BIT, p);
    printf("  graphics [fail] FAIL_ON_PIPELINE_COMPILE_REQUIRED: %d, handle %s\n", r,
           p[0] ? "set" : "null");
    destroy_pipelines(1, p);

    memset(p, 0, sizeof(p));
    r = create_gfx(VK_NULL_HANDLE, 3, fok, VK_PIPELINE_CREATE_EARLY_RETURN_ON_FAILURE_BIT, p);
    printf("  graphics [fail, ok, ok] EARLY_RETURN_ON_FAILURE: %d, handles %s %s %s\n", r,
           p[0] ? "set" : "null", p[1] ? "set" : "null", p[2] ? "set" : "null");
    use_pipelines(3, p, 0, NULL);
    destroy_pipelines(3, p);

    memset(p, 0, sizeof(p));
    r = create_compute(VK_NULL_HANDLE, 3, fok,
                       VK_PIPELINE_CREATE_FAIL_ON_PIPELINE_COMPILE_REQUIRED_BIT, p);
    printf("  compute [fail, ok, ok] FAIL_ON_PIPELINE_COMPILE_REQUIRED: %d, handles %s %s %s\n",
           r, p[0] ? "set" : "null", p[1] ? "set" : "null", p[2] ? "set" : "null");
    use_pipelines(0, NULL, 3, p);
    destroy_pipelines(3, p);
}

static void test_pipe_cache(void)
{
    VkPipelineCacheCreateInfo pcci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO };
    VkPipelineCache cache;
    CHECK(vkCreatePipelineCache(dev, &pcci, NULL, &cache));
    const bool mixed[2] = { true, false };
    VkPipeline g[2] = { 0 }, c[2] = { 0 };
    printf("  graphics [fail, ok] with cache: %d\n", create_gfx(cache, 2, mixed, 0, g));
    printf("  compute [fail, ok] with cache: %d\n", create_compute(cache, 2, mixed, 0, c));
    use_pipelines(2, g, 2, c);
    size_t size = 0;
    VkResult r = vkGetPipelineCacheData(dev, cache, &size, NULL);
    printf("  cache data: %d, %zu bytes\n", r, size);
    destroy_pipelines(2, g);
    destroy_pipelines(2, c);
    vkDestroyPipelineCache(dev, cache, NULL);
}

// --- memory, images, buffers

static void test_mem_export(void)
{
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pdev, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
        VkExportMemoryAllocateInfo export = {
            .sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
            .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };
        VkMemoryAllocateInfo mai = {
            .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = &export,
            .allocationSize = 4096,
            .memoryTypeIndex = i,
        };
        VkDeviceMemory mem = VK_NULL_HANDLE;
        VkResult r = vkAllocateMemory(dev, &mai, NULL, &mem);
        printf("  memory type %u (flags 0x%x, heap %u): dma_buf export alloc %d\n", i,
               mp.memoryTypes[i].propertyFlags, mp.memoryTypes[i].heapIndex, r);
        if (r == VK_SUCCESS)
            vkFreeMemory(dev, mem, NULL);
    }
}

static void test_mem_huge(void)
{
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pdev, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
        const VkDeviceSize size = mp.memoryHeaps[mp.memoryTypes[i].heapIndex].size * 4;
        for (int exp = 0; exp < 2; exp++) {
            VkExportMemoryAllocateInfo export = {
                .sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
                .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
            };
            VkMemoryAllocateInfo mai = {
                .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .pNext = exp ? &export : NULL,
                .allocationSize = size,
                .memoryTypeIndex = i,
            };
            VkDeviceMemory mem = VK_NULL_HANDLE;
            VkResult r = vkAllocateMemory(dev, &mai, NULL, &mem);
            printf("  memory type %u: %llu MiB%s alloc %d\n", i,
                   (unsigned long long)(size >> 20), exp ? " dma_buf export" : "", r);
            if (r == VK_SUCCESS)
                vkFreeMemory(dev, mem, NULL);
        }
    }
}

static void test_image_buffer(void)
{
    VkImageCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = { 1u << 20, 1u << 20, 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_SAMPLED_BIT,
    };
    VkImage image = VK_NULL_HANDLE;
    printf("  image 1Mi x 1Mi: %d\n", vkCreateImage(dev, &ici, NULL, &image));
    vkDestroyImage(dev, image, NULL);

    VkBufferCreateInfo bci = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = 1ull << 44,
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
    };
    VkBuffer buffer = VK_NULL_HANDLE;
    printf("  buffer 16 TiB: %d\n", vkCreateBuffer(dev, &bci, NULL, &buffer));
    vkDestroyBuffer(dev, buffer, NULL);
}

static volatile bool stop_workers;

static void *busy_pipe_worker(void *arg)
{
    (void)arg;
    for (int i = 0; !stop_workers; i++) {
        const bool fail[2] = { true, i % 2 };
        VkPipeline p[2] = { 0 };
        create_gfx(VK_NULL_HANDLE, 2, fail, 0, p);
        destroy_pipelines(2, p);
    }
    return NULL;
}

// Expected to kill the context: worker threads keep their rings busy creating pipelines
// while this thread binds VK_NULL_HANDLE (fatal on the host by design).  The host log must
// show one CS error, for vkCmdBindPipeline's stream, and "<command> stopped: the context went
// fatal on another thread" for the busy rings.  Not run by default.
static void test_fatal_attribution(void)
{
    pthread_t t[6];
    for (int i = 0; i < 6; i++)
        pthread_create(&t[i], NULL, busy_pipe_worker, NULL);
    struct timespec ts = { 0, 200 * 1000 * 1000 };
    nanosleep(&ts, NULL);

    VkCommandBufferAllocateInfo ai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = cmd_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer cmd;
    CHECK(vkAllocateCommandBuffers(dev, &ai, &cmd));
    VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    CHECK(vkBeginCommandBuffer(cmd, &bi));
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, VK_NULL_HANDLE);
    CHECK(vkEndCommandBuffer(cmd));
    VkSubmitInfo si = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
    };
    vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE);
    vkQueueWaitIdle(queue);
    stop_workers = true;
    for (int i = 0; i < 6; i++)
        pthread_join(t[i], NULL);
}

static const struct {
    const char *name;
    void (*run)(void);
    bool explicit_only; // kills the context; only when named
} tests[] = {
    { "pipe-async", test_pipe_async, false },
    { "pipe-threads", test_pipe_threads, false },
    { "pipe-flags", test_pipe_flags, false },
    { "pipe-cache", test_pipe_cache, false },
    { "mem-export", test_mem_export, false },
    { "mem-huge", test_mem_huge, false },
    { "image-buffer", test_image_buffer, false },
    { "fatal-attribution", test_fatal_attribution, true },
};

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    init();
    probe("init");
    const size_t n = sizeof(tests) / sizeof(tests[0]);
    for (size_t i = 0; i < n; i++) {
        bool run = argc < 2 && !tests[i].explicit_only;
        for (int a = 1; a < argc; a++)
            run |= !strcmp(argv[a], tests[i].name);
        if (!run)
            continue;
        printf("%s:\n", tests[i].name);
        tests[i].run();
        probe(tests[i].name);
    }
    vkDestroyImageView(dev, color_view, NULL);
    vkDestroyImage(dev, color_image, NULL);
    vkFreeMemory(dev, color_mem, NULL);
    vkDestroyShaderModule(dev, vs, NULL);
    vkDestroyShaderModule(dev, fs, NULL);
    vkDestroyShaderModule(dev, fs_bad, NULL);
    vkDestroyShaderModule(dev, cs, NULL);
    vkDestroyPipelineLayout(dev, layout, NULL);
    vkDestroyCommandPool(dev, cmd_pool, NULL);
    vkDestroyDevice(dev, NULL);
    vkDestroyInstance(instance, NULL);
    printf("all done\n");
    return 0;
}
