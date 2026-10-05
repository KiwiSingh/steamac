/*
 * Performance of the steamac MoltenVK/SPIRV-Cross changes, against one libMoltenVK (bench/run.sh compares
 * builds). Each benchmark submits the same command buffer repeatedly (MoltenVK encodes it to Metal at every
 * vkQueueSubmit) and prints
 *     BENCH <name> <median ms> <min ms> <median vkQueueSubmit ms>
 * per submit + wait (vkQueueSubmit is the CPU encoding time), or "BENCH <name> n/a <reason>".
 *
 *   bda_load / ssbo_load   1M invocations, 256 gathered vector-component loads + 1 component store each,
 *                          through a buffer device address / a storage buffer descriptor (SPIRV-Cross 0019 keeps
 *                          BDA component loads as they were: the scalar-pointer cast of SSBO components and of
 *                          BDA atomics made them 5% slower)
 *   bda_atomic             1M invocations x 16 atomicAdd on BDA vector components (did not compile before 0019)
 *   xfb_draws              256 capturing geometry-shader draws (so_points.geom, 6 vertices each) in one
 *   xfb_draws_query        render pass, without / with an active transform feedback query (MoltenVK 0028)
 *   occl_copy_each         4096 occlusion queries copied one vkCmdCopyQueryPoolResults each, 64-bit with
 *                          availability and wait (Venus' query feedback; MoltenVK 0027 binds the availability
 *                          of the copied queries instead of the whole pool for each copy)
 *   occl_copy_all          the 4096 occlusion queries in one packed 64-bit copy (blit path), 64 times
 *   xfb_copy_each          the same per-query copies for 4096 transform feedback queries (0028)
 *   occl_get / xfb_get     vkGetQueryPoolResults of the 4096 queries, 64-bit with availability
 *
 *   bench <spv dir> <repro spv dir>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

enum { W = 16, H = 16, REPS = 40, QUERIES = 4096 };

static VkDevice dev;
static VkPhysicalDevice pd;
static VkQueue queue;
static VkCommandPool cmd_pool;
static PFN_vkCmdBindTransformFeedbackBuffersEXT bind_xfb;
static PFN_vkCmdBeginTransformFeedbackEXT begin_xfb;
static PFN_vkCmdEndTransformFeedbackEXT end_xfb;

static double now_ms(void)
{
	return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6;
}

static int cmp_double(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

static VkShaderModule module(const char *dir, const char *name)
{
	char path[1024];
	snprintf(path, sizeof(path), "%s/%s", dir, name);
	FILE *f = fopen(path, "rb");
	if (!f) { printf("FAIL open %s\n", path); exit(1); }
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint32_t *code = malloc(n);
	if (fread(code, 1, n, f) != (size_t)n) { printf("FAIL read %s\n", path); exit(1); }
	fclose(f);
	VkShaderModuleCreateInfo ci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = n, .pCode = code };
	VkShaderModule m;
	CK(vkCreateShaderModule(dev, &ci, NULL, &m));
	free(code);
	return m;
}

static uint32_t mem_type(uint32_t bits, VkMemoryPropertyFlags want)
{
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
			return i;
	printf("FAIL no memory type\n");
	exit(1);
}

/* Buffer with its own memory; mapped if map is given (host-visible), device-local otherwise. */
static VkBuffer buffer(VkDeviceSize size, VkBufferUsageFlags usage, void **map)
{
	VkBufferCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage };
	VkBuffer b;
	CK(vkCreateBuffer(dev, &ci, NULL, &b));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, b, &mr);
	VkMemoryAllocateFlagsInfo fi = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO, .flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT };
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.pNext = (usage & VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT) ? &fi : NULL, .allocationSize = mr.size,
		.memoryTypeIndex = mem_type(mr.memoryTypeBits, map ? VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
		                                                   : VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
	VkDeviceMemory m;
	CK(vkAllocateMemory(dev, &ai, NULL, &m));
	CK(vkBindBufferMemory(dev, b, m, 0));
	if (map)
		CK(vkMapMemory(dev, m, 0, VK_WHOLE_SIZE, 0, map));
	return b;
}

static VkCommandBuffer new_cmd(void)
{
	VkCommandBufferAllocateInfo ai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cmd_pool,
		.commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &ai, &cmd));
	VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CK(vkBeginCommandBuffer(cmd, &bi));
	return cmd;
}

static void submit_wait(VkCommandBuffer cmd)
{
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));
}

/* Submits cmd REPS times (after 3 warm-up submits), each after setup (if any), and reports the times. */
static void time_submits(const char *name, VkCommandBuffer setup, VkCommandBuffer cmd)
{
	double total[REPS], submit[REPS];
	for (int i = -3; i < REPS; i++) {
		if (setup)
			submit_wait(setup);
		VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
		double t0 = now_ms();
		CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
		double t1 = now_ms();
		CK(vkQueueWaitIdle(queue));
		double t2 = now_ms();
		if (i >= 0) {
			total[i] = t2 - t0;
			submit[i] = t1 - t0;
		}
	}
	qsort(total, REPS, sizeof(double), cmp_double);
	qsort(submit, REPS, sizeof(double), cmp_double);
	printf("BENCH %-18s %10.3f %10.3f %10.3f\n", name, total[REPS / 2], total[0], submit[REPS / 2]);
}

static void na(const char *name, const char *why, VkResult r)
{
	printf("BENCH %-18s n/a %s (VkResult %d)\n", name, why, r);
}

/* bda_load, ssbo_load, bda_atomic */
static void bench_compute(const char *name, const char *dir, const char *spv, int ssbo)
{
	const uint32_t elements = 1u << 20;
	VkBuffer data = buffer((VkDeviceSize)elements * 16, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT |
	                                                     VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT, NULL);
	VkDescriptorSetLayoutBinding b = { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL };
	VkDescriptorSetLayoutCreateInfo dslci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &b };
	VkDescriptorSetLayout dsl;
	CK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
	VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, 16 };
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = ssbo ? 1 : 0,
		.pSetLayouts = &dsl, .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
		           .module = module(dir, spv), .pName = "main" }, .layout = layout };
	VkPipeline p;
	VkResult r = vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p);
	if (r) { na(name, "pipeline creation failed", r); return; }

	VkDescriptorSet set = VK_NULL_HANDLE;
	if (ssbo) {
		VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
		VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps };
		VkDescriptorPool dp;
		CK(vkCreateDescriptorPool(dev, &dpci, NULL, &dp));
		VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp,
			.descriptorSetCount = 1, .pSetLayouts = &dsl };
		CK(vkAllocateDescriptorSets(dev, &dsai, &set));
		VkDescriptorBufferInfo dbi = { data, 0, VK_WHOLE_SIZE };
		VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .descriptorCount = 1,
			.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi };
		vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);
	}
	VkBufferDeviceAddressInfo bdai = { VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, .buffer = data };
	struct { uint64_t address; uint32_t mask, pad; } pc = { vkGetBufferDeviceAddress(dev, &bdai), elements - 1, 0 };

	VkCommandBuffer fill = new_cmd();
	vkCmdFillBuffer(fill, data, 0, VK_WHOLE_SIZE, 1);
	CK(vkEndCommandBuffer(fill));
	submit_wait(fill);

	VkCommandBuffer cmd = new_cmd();
	vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p);
	if (set)
		vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
	vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(pc), &pc);
	vkCmdDispatch(cmd, elements / 64, 1, 1);
	CK(vkEndCommandBuffer(cmd));
	time_submits(name, VK_NULL_HANDLE, cmd);
}

static void begin_rendering(VkCommandBuffer cmd, VkImageView view)
{
	VkRenderingAttachmentInfo att = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
		.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
		.storeOp = VK_ATTACHMENT_STORE_OP_STORE };
	VkRenderingInfo ri = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { W, H } }, .layerCount = 1,
		.colorAttachmentCount = 1, .pColorAttachments = &att };
	vkCmdBeginRendering(cmd, &ri);
}

static VkImageView color_target(void)
{
	VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT };
	VkImage img;
	CK(vkCreateImage(dev, &ci, NULL, &img));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(dev, img, &mr);
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = mem_type(mr.memoryTypeBits, 0) };
	VkDeviceMemory m;
	CK(vkAllocateMemory(dev, &ai, NULL, &m));
	CK(vkBindImageMemory(dev, img, m, 0));
	VkImageViewCreateInfo vci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img, .viewType = VK_IMAGE_VIEW_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView view;
	CK(vkCreateImageView(dev, &vci, NULL, &view));
	return view;
}

/* xfb_draws, xfb_draws_query: so.vert + so_points.geom (3 points without position per input triangle,
 * rasterizer discard, no fragment shader), as in repro/xfb.c. */
static void bench_xfb(const char *name, const char *repro_dir, VkImageView view, int with_query)
{
	enum { DRAWS = 256 };
	VkQueryPool qp = VK_NULL_HANDLE;
	if (with_query) {
		VkQueryPoolCreateInfo qci = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
			.queryType = VK_QUERY_TYPE_TRANSFORM_FEEDBACK_STREAM_EXT, .queryCount = 1 };
		VkResult r = vkCreateQueryPool(dev, &qci, NULL, &qp);
		if (r) { na(name, "transform feedback query pool creation failed", r); return; }
	}
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkPipelineShaderStageCreateInfo st[2] = {
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
		  .module = module(repro_dir, "so.vert.spv"), .pName = "main" },
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_GEOMETRY_BIT,
		  .module = module(repro_dir, "so_points.geom.spv"), .pName = "main" },
	};
	VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
	VkViewport vp = { 0, 0, W, H, 0, 1 };
	VkRect2D sc = { { 0, 0 }, { W, H } };
	VkPipelineViewportStateCreateInfo vps = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1,
		.pViewports = &vp, .scissorCount = 1, .pScissors = &sc };
	VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.rasterizerDiscardEnable = VK_TRUE, .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
	VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1,
		.pAttachments = &cba };
	VkFormat cf = VK_FORMAT_R8G8B8A8_UNORM;
	VkPipelineRenderingCreateInfo ri = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .colorAttachmentCount = 1,
		.pColorAttachmentFormats = &cf };
	VkGraphicsPipelineCreateInfo gci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, &ri, .stageCount = 2, .pStages = st,
		.pVertexInputState = &vi, .pInputAssemblyState = &ia, .pViewportState = &vps, .pRasterizationState = &rs,
		.pMultisampleState = &ms, .pColorBlendState = &cb, .layout = layout };
	VkPipeline p;
	VkResult r = vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gci, NULL, &p);
	if (r) { na(name, "pipeline creation failed", r); return; }

	VkDeviceSize size = DRAWS * 6 * 40;
	VkBuffer xbuf = buffer(size, VK_BUFFER_USAGE_TRANSFORM_FEEDBACK_BUFFER_BIT_EXT, NULL);
	VkDeviceSize zero = 0;
	VkCommandBuffer cmd = new_cmd();
	if (qp)
		vkCmdResetQueryPool(cmd, qp, 0, 1);
	begin_rendering(cmd, view);
	vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p);
	bind_xfb(cmd, 0, 1, &xbuf, &zero, &size);
	begin_xfb(cmd, 0, 0, NULL, NULL);
	if (qp)
		vkCmdBeginQuery(cmd, qp, 0, 0);
	for (int i = 0; i < DRAWS; i++)
		vkCmdDraw(cmd, 6, 1, 0, 0);
	if (qp)
		vkCmdEndQuery(cmd, qp, 0);
	end_xfb(cmd, 0, 0, NULL, NULL);
	vkCmdEndRendering(cmd);
	CK(vkEndCommandBuffer(cmd));
	time_submits(name, VK_NULL_HANDLE, cmd);
}

/* QUERIES queries of the pool begun and ended (no draws) in a render pass, after a reset. */
static VkCommandBuffer query_setup(VkQueryPool qp, VkImageView view)
{
	VkCommandBuffer cmd = new_cmd();
	vkCmdResetQueryPool(cmd, qp, 0, QUERIES);
	begin_rendering(cmd, view);
	for (uint32_t q = 0; q < QUERIES; q++) {
		vkCmdBeginQuery(cmd, qp, q, 0);
		vkCmdEndQuery(cmd, qp, q);
	}
	vkCmdEndRendering(cmd);
	CK(vkEndCommandBuffer(cmd));
	return cmd;
}

/* occl_copy_each, occl_copy_all, xfb_copy_each, occl_get, xfb_get */
static void bench_queries(const char *prefix, VkQueryType type, uint32_t elements, VkImageView view)
{
	char name[64];
	VkQueryPoolCreateInfo qci = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = type, .queryCount = QUERIES };
	VkQueryPool qp;
	VkResult r = vkCreateQueryPool(dev, &qci, NULL, &qp);
	if (r) {
		snprintf(name, sizeof(name), "%s_copy_each", prefix);
		na(name, "query pool creation failed", r);
		snprintf(name, sizeof(name), "%s_get", prefix);
		na(name, "query pool creation failed", r);
		return;
	}
	VkCommandBuffer setup = query_setup(qp, view);
	const VkDeviceSize slot = elements * 8 + 8;
	void *map;
	VkBuffer dst = buffer(QUERIES * slot, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &map);

	/* Venus' query feedback: one copy per ended query. */
	VkCommandBuffer each = new_cmd();
	for (uint32_t q = 0; q < QUERIES; q++)
		vkCmdCopyQueryPoolResults(each, qp, q, 1, dst, q * slot, slot,
		                          VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT | VK_QUERY_RESULT_WAIT_BIT);
	CK(vkEndCommandBuffer(each));
	snprintf(name, sizeof(name), "%s_copy_each", prefix);
	time_submits(name, setup, each);

	if (type == VK_QUERY_TYPE_OCCLUSION) {
		VkCommandBuffer all = new_cmd();
		for (int i = 0; i < 64; i++)
			vkCmdCopyQueryPoolResults(all, qp, 0, QUERIES, dst, 0, elements * 8, VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT);
		CK(vkEndCommandBuffer(all));
		snprintf(name, sizeof(name), "%s_copy_all", prefix);
		time_submits(name, setup, all);
	}

	submit_wait(setup);
	static uint64_t results[QUERIES * 3];
	double t[REPS];
	for (int i = -3; i < REPS; i++) {
		double t0 = now_ms();
		for (int k = 0; k < 10; k++)
			vkGetQueryPoolResults(dev, qp, 0, QUERIES, QUERIES * slot, results, slot,
			                      VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT);
		if (i >= 0)
			t[i] = (now_ms() - t0) / 10;
	}
	qsort(t, REPS, sizeof(double), cmp_double);
	snprintf(name, sizeof(name), "%s_get", prefix);
	printf("BENCH %-18s %10.3f %10.3f %10.3f\n", name, t[REPS / 2], t[0], 0.0);
}

int main(int argc, char **argv)
{
	if (argc != 3) { fprintf(stderr, "usage: %s <spv dir> <repro spv dir>\n", argv[0]); return 2; }
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	VkPhysicalDeviceTransformFeedbackFeaturesEXT xfbf = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT,
		.transformFeedback = VK_TRUE };
	VkPhysicalDeviceVulkan12Features v12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &xfbf,
		.bufferDeviceAddress = VK_TRUE };
	VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, &v12,
		.dynamicRendering = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v13,
		.features = { .geometryShader = VK_TRUE, .shaderInt64 = VK_TRUE } };
	const char *exts[] = { VK_EXT_TRANSFORM_FEEDBACK_EXTENSION_NAME };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
		.enabledExtensionCount = 1, .ppEnabledExtensionNames = exts };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	vkGetDeviceQueue(dev, 0, 0, &queue);
	bind_xfb = (PFN_vkCmdBindTransformFeedbackBuffersEXT)vkGetDeviceProcAddr(dev, "vkCmdBindTransformFeedbackBuffersEXT");
	begin_xfb = (PFN_vkCmdBeginTransformFeedbackEXT)vkGetDeviceProcAddr(dev, "vkCmdBeginTransformFeedbackEXT");
	end_xfb = (PFN_vkCmdEndTransformFeedbackEXT)vkGetDeviceProcAddr(dev, "vkCmdEndTransformFeedbackEXT");
	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	CK(vkCreateCommandPool(dev, &cpci, NULL, &cmd_pool));
	VkImageView view = color_target();

	bench_compute("bda_load", argv[1], "bda_load.comp.spv", 0);
	bench_compute("ssbo_load", argv[1], "ssbo_load.comp.spv", 1);
	bench_compute("bda_atomic", argv[1], "bda_atomic.comp.spv", 0);
	bench_xfb("xfb_draws", argv[2], view, 0);
	bench_xfb("xfb_draws_query", argv[2], view, 1);
	bench_queries("occl", VK_QUERY_TYPE_OCCLUSION, 1, view);
	bench_queries("xfb", VK_QUERY_TYPE_TRANSFORM_FEEDBACK_STREAM_EXT, 2, view);
	return 0;
}
