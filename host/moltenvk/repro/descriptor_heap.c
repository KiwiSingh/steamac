/*
 * vkd3d-proton's D3D12 descriptor heaps without descriptor buffers or mutable descriptors (the legacy bindless
 * path, libs/vkd3d/state.c vkd3d_bindless_state_init_legacy + resource.c d3d12_descriptor_heap_create_descriptor_pool /
 * _create_descriptor_set, master b206eb6), as Venus forwards them to MoltenVK:
 *   - one set layout per descriptor type, each one variable-count update-after-bind binding of 1000000 descriptors
 *     (D3D12 resource binding tier 2), the CBV set (and only it) with two storage buffers in front (raw VA aux
 *     buffer, offset buffer); host (non-shader-visible) layouts with the maxDescriptorSetUpdateAfterBind* limit;
 *   - per heap a pool with one pool size of NumDescriptors per set of the heap's type (+2 storage buffers for the
 *     CBV set's extra bindings), maxSets = number of pool sizes, UPDATE_AFTER_BIND;
 *   - each set allocated with variableDescriptorCount = NumDescriptors, then every descriptor written null.
 * 1. Heaps of the sizes games create (Stellar Blade, UE4: CBV_SRV_UAV shader-visible heaps up to 1000000, samplers
 *    2048, many small host heaps) and pools of a single such set, sized exactly: every set allocates. A failed
 *    allocation is fatal over Venus: the guest allocates sets asynchronously, the host's VK_ERROR_OUT_OF_POOL_MEMORY
 *    leaves a set handle the next vkUpdateDescriptorSets cannot find, and the context's command stream stops (the
 *    game hung on its first frame).
 * 2. dh_read.comp reads descriptors at element 999997 of a 1000000-descriptor heap: an R32_UINT texel buffer view at
 *    byte 4 (texel offset), a raw SSBO at byte 16 through two declarations of its binding (restrict uint[] and
 *    uvec4[]: the second one's cast dropped __restrict and the pipeline did not compile), a CBV, and the CBV set's
 *    fixed offset buffer (sizes and texel offset come from the sets' aux buffers, which start after the variable
 *    descriptors).
 * 3. A graphics pipeline whose fragment shader (heap/dh_loop_header.spvasm, Stellar Blade's shape) loads heap
 *    descriptors in a loop header block and uses them in the loop body: SPIRV-Cross declared their access chains
 *    as temporaries ("constant texture3d<float> _45;"), Metal rejected the shader, vkd3d-proton's pipeline failed
 *    and the game exited with "Out of video memory".
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

enum { MAX_VIEWS = 1000000, MAX_SAMPLERS = 2048, EXTRA_SSBOS = 2 };
enum { CBV, SRV_BUFFER, SRV_IMAGE, UAV_BUFFER, UAV_IMAGE, RAW_SSBO, VIEW_SETS };

static VkDevice dev;
static VkPhysicalDevice pd;
static const char *dir;
static int fails;

struct heap_set {
	const char *name;
	VkDescriptorType type;
	uint32_t extra;                 /* storage buffers in front of the heap binding */
	VkDescriptorSetLayout layout;   /* shader-visible heaps */
	VkDescriptorSetLayout host;     /* host heaps */
};

static VkDescriptorSetLayout heap_layout(VkDescriptorType type, uint32_t extra, uint32_t count)
{
	VkDescriptorSetLayoutBinding b[EXTRA_SSBOS + 1];
	VkDescriptorBindingFlags f[EXTRA_SSBOS + 1];
	for (uint32_t i = 0; i < extra; i++) {
		b[i] = (VkDescriptorSetLayoutBinding){ i, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL };
		f[i] = 0;
	}
	b[extra] = (VkDescriptorSetLayoutBinding){ extra, type, count, VK_SHADER_STAGE_ALL, NULL };
	f[extra] = VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT | VK_DESCRIPTOR_BINDING_UPDATE_UNUSED_WHILE_PENDING_BIT |
	           VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT | VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT;
	VkDescriptorSetLayoutBindingFlagsCreateInfo fci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		.bindingCount = extra + 1, .pBindingFlags = f };
	VkDescriptorSetLayoutCreateInfo ci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, &fci,
		.flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT, .bindingCount = extra + 1, .pBindings = b };
	VkDescriptorSetLayout l;
	CK(vkCreateDescriptorSetLayout(dev, &ci, NULL, &l));
	return l;
}

/* d3d12_descriptor_heap_zero_initialize: every descriptor of the heap binding written null. */
static void zero_initialize(VkDescriptorSet set, VkDescriptorType type, uint32_t binding, uint32_t count)
{
	VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = binding,
		.descriptorCount = count, .descriptorType = type };
	void *infos = NULL;
	switch (type) {
	case VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE:
	case VK_DESCRIPTOR_TYPE_STORAGE_IMAGE:
		w.pImageInfo = infos = calloc(count, sizeof(VkDescriptorImageInfo));
		break;
	case VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER:
	case VK_DESCRIPTOR_TYPE_STORAGE_BUFFER: {
		VkDescriptorBufferInfo *bi = calloc(count, sizeof(*bi));
		for (uint32_t i = 0; i < count; i++)
			bi[i].range = VK_WHOLE_SIZE;
		w.pBufferInfo = infos = bi;
		break;
	}
	case VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER:
	case VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER:
		w.pTexelBufferView = infos = calloc(count, sizeof(VkBufferView));
		break;
	default:
		return;   /* samplers are not zero-initialized */
	}
	vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);
	free(infos);
}

/*
 * d3d12_descriptor_heap_create_descriptor_pool + _create_descriptor_set for each of the sets. Returns the pool
 * (the sets in `out`) if `keep`, else destroys it.
 */
static VkDescriptorPool heap(const char *what, const struct heap_set *sets, uint32_t set_count, uint32_t num_descriptors,
                             int shader_visible, VkDescriptorSet *out, int keep)
{
	VkDescriptorPoolSize sizes[VIEW_SETS + 1];
	uint32_t pool_count = 0, ssbo_pool = ~0u, ssbo_extra = 0;
	for (uint32_t i = 0; i < set_count; i++) {
		if (sets[i].type == VK_DESCRIPTOR_TYPE_STORAGE_BUFFER)
			ssbo_pool = pool_count;
		sizes[pool_count++] = (VkDescriptorPoolSize){ sets[i].type, num_descriptors };
		ssbo_extra += sets[i].extra;
	}
	if (ssbo_extra && ssbo_pool == ~0u) {
		ssbo_pool = pool_count;
		sizes[pool_count++] = (VkDescriptorPoolSize){ VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 0 };
	}
	if (ssbo_extra)
		sizes[ssbo_pool].descriptorCount += ssbo_extra;
	VkDescriptorPoolCreateInfo pci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
		.flags = VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT, .maxSets = pool_count, .poolSizeCount = pool_count, .pPoolSizes = sizes };
	VkDescriptorPool pool;
	VkResult r = vkCreateDescriptorPool(dev, &pci, NULL, &pool);
	if (r) {
		printf("FAIL %s: vkCreateDescriptorPool = %d\n", what, r);
		fails++;
		return VK_NULL_HANDLE;
	}
	char failed[256] = "";
	for (uint32_t i = 0; i < set_count; i++) {
		VkDescriptorSetVariableDescriptorCountAllocateInfo vci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
			.descriptorSetCount = 1, .pDescriptorCounts = &num_descriptors };
		VkDescriptorSetAllocateInfo ai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, &vci, .descriptorPool = pool,
			.descriptorSetCount = 1, .pSetLayouts = shader_visible ? &sets[i].layout : &sets[i].host };
		r = vkAllocateDescriptorSets(dev, &ai, &out[i]);
		if (r) {
			snprintf(failed + strlen(failed), sizeof(failed) - strlen(failed), " %s=%d", sets[i].name, r);
			continue;
		}
		zero_initialize(out[i], sets[i].type, sets[i].extra, num_descriptors);
	}
	printf("%-4s %s: %u sets of %u descriptors allocated%s%s\n", failed[0] ? "FAIL" : "OK", what, set_count, num_descriptors,
	       failed[0] ? ", failed:" : "", failed);
	fails += failed[0] != 0;
	if (keep && !failed[0])
		return pool;
	vkDestroyDescriptorPool(dev, pool, NULL);
	return VK_NULL_HANDLE;
}

static VkShaderModule module(const char *name)
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

/* Host-visible buffer, mapped. */
static VkBuffer buffer(VkDeviceSize size, VkBufferUsageFlags usage, void **map)
{
	VkBufferCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage };
	VkBuffer b;
	CK(vkCreateBuffer(dev, &ci, NULL, &b));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, b, &mr);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	const VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
	uint32_t t = 0;
	while (!(mr.memoryTypeBits & (1u << t)) || (mp.memoryTypes[t].propertyFlags & want) != want)
		t++;
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = t };
	VkDeviceMemory m;
	CK(vkAllocateMemory(dev, &ai, NULL, &m));
	CK(vkBindBufferMemory(dev, b, m, 0));
	CK(vkMapMemory(dev, m, 0, VK_WHOLE_SIZE, 0, map));
	return b;
}

static void expect(const char *what, const uint32_t *got, const uint32_t *want, uint32_t count)
{
	uint32_t bad = 0;
	for (uint32_t i = 0; i < count; i++)
		if (got[i] != want[i]) {
			if (!bad)
				printf("     %s: [%u] = %u, want %u\n", what, i, got[i], want[i]);
			bad++;
		}
	printf("%-4s %s (%u values, %u wrong)\n", bad ? "FAIL" : "OK", what, count, bad);
	fails += bad != 0;
}

/* 2. dh_read.comp through a shader-visible heap of MAX_VIEWS. */
static void read_heap(const struct heap_set *views, VkQueue queue)
{
	const uint32_t k = MAX_VIEWS - 3;
	VkDescriptorSet sets[VIEW_SETS];
	VkDescriptorPool pool = heap("shader-visible CBV_SRV_UAV heap of 1000000 for dh_read.comp", views, VIEW_SETS, MAX_VIEWS, 1, sets, 1);
	if (!pool)
		return;

	uint32_t *data, *out;
	VkBuffer dbuf = buffer(256, VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
	                            VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, (void **)&data);
	VkBuffer obuf = buffer(64, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, (void **)&out);
	for (uint32_t i = 0; i < 64; i++)
		data[i] = 100 + i;
	memset(out, 0xcd, 64);

	VkBufferViewCreateInfo bvci = { VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO, .buffer = dbuf, .format = VK_FORMAT_R32_UINT,
		.offset = 4, .range = 64 };
	VkBufferView view;
	CK(vkCreateBufferView(dev, &bvci, NULL, &view));
	VkDescriptorBufferInfo raw = { dbuf, 16, 32 }, cbv = { dbuf, 0, 16 }, offs = { dbuf, 0, 64 }, aux = { dbuf, 0, 16 };
	VkWriteDescriptorSet w[] = {
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = sets[SRV_BUFFER], .dstBinding = 0, .dstArrayElement = k,
		  .descriptorCount = 1, .descriptorType = views[SRV_BUFFER].type, .pTexelBufferView = &view },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = sets[RAW_SSBO], .dstBinding = 0, .dstArrayElement = k,
		  .descriptorCount = 1, .descriptorType = views[RAW_SSBO].type, .pBufferInfo = &raw },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = sets[CBV], .dstBinding = EXTRA_SSBOS, .dstArrayElement = k,
		  .descriptorCount = 1, .descriptorType = views[CBV].type, .pBufferInfo = &cbv },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = sets[CBV], .dstBinding = 0,
		  .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &aux },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = sets[CBV], .dstBinding = 1,
		  .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &offs },
	};
	vkUpdateDescriptorSets(dev, sizeof(w) / sizeof(*w), w, 0, NULL);

	VkDescriptorSetLayoutBinding ob = { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL };
	VkDescriptorSetLayoutCreateInfo oci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &ob };
	VkDescriptorSetLayout olayout;
	CK(vkCreateDescriptorSetLayout(dev, &oci, NULL, &olayout));
	VkDescriptorPoolSize ops = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
	VkDescriptorPoolCreateInfo opci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ops };
	VkDescriptorPool opool;
	CK(vkCreateDescriptorPool(dev, &opci, NULL, &opool));
	VkDescriptorSetAllocateInfo oai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = opool,
		.descriptorSetCount = 1, .pSetLayouts = &olayout };
	VkDescriptorSet oset;
	CK(vkAllocateDescriptorSets(dev, &oai, &oset));
	VkDescriptorBufferInfo obi = { obuf, 0, VK_WHOLE_SIZE };
	VkWriteDescriptorSet ow = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = oset, .dstBinding = 0, .descriptorCount = 1,
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &obi };
	vkUpdateDescriptorSets(dev, 1, &ow, 0, NULL);

	VkDescriptorSetLayout layouts[] = { views[SRV_BUFFER].layout, views[RAW_SSBO].layout, views[CBV].layout, olayout };
	VkDescriptorSet bind[] = { sets[SRV_BUFFER], sets[RAW_SSBO], sets[CBV], oset };
	VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, 4 };
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 4, .pSetLayouts = layouts,
		.pushConstantRangeCount = 1, .pPushConstantRanges = &pcr };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
		           .module = module("dh_read.comp.spv"), .pName = "main" }, .layout = layout };
	VkPipeline p;
	VkResult r = vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p);
	printf("%-4s create dh_read.comp.spv (VkResult %d)\n", r ? "FAIL" : "OK", r);
	if (r) exit(1);

	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool cpool;
	CK(vkCreateCommandPool(dev, &cpci, NULL, &cpool));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cpool, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
	VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	CK(vkBeginCommandBuffer(cmd, &bi));
	vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p);
	vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 4, bind, 0, NULL);
	vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 4, &k);
	vkCmdDispatch(cmd, 1, 1, 1);
	VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));

	/* view at byte 4: texel 2 = word 3, 16 texels, texel 16 past the end; raw SSBO at byte 16: word 1 = 105,
	 * 8 words, as uvec4[0].w word 7; CBV v.y = 101; offset buffer 64 bytes = 16 words */
	const uint32_t want[] = { 103, 16, 0, 105, 8, 101, 16, 107 };
	expect("element 999997: texel view at 4 (texel 2, size, past the end), raw SSBO at 16 (word 1, length, uvec4 alias), "
	       "CBV, fixed offset buffer length", out, want, 8);
	vkDestroyDescriptorPool(dev, pool, NULL);
}

/* 3. */
static void loop_header_pipeline(const struct heap_set *views, const struct heap_set *sampler)
{
	VkDescriptorSetLayout layouts[] = { views[SRV_IMAGE].layout, sampler[0].layout };
	VkPushConstantRange pcr = { VK_SHADER_STAGE_FRAGMENT_BIT, 0, 8 };
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 2, .pSetLayouts = layouts,
		.pushConstantRangeCount = 1, .pPushConstantRanges = &pcr };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkPipelineShaderStageCreateInfo stages[] = {
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
		  .module = module("dh_fullscreen.vert.spv"), .pName = "main" },
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
		  .module = module("dh_loop_header.spv"), .pName = "main" },
	};
	VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
	VkViewport vp = { 0, 0, 4, 4, 0, 1 };
	VkRect2D sc = { { 0, 0 }, { 4, 4 } };
	VkPipelineViewportStateCreateInfo vps = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		.viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc };
	VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
	VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = 1, .pAttachments = &cba };
	VkFormat fmt = VK_FORMAT_R8G8B8A8_UNORM;
	VkPipelineRenderingCreateInfo rci = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
		.colorAttachmentCount = 1, .pColorAttachmentFormats = &fmt };
	VkGraphicsPipelineCreateInfo ci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, &rci, .stageCount = 2, .pStages = stages,
		.pVertexInputState = &vi, .pInputAssemblyState = &ia, .pViewportState = &vps, .pRasterizationState = &rs,
		.pMultisampleState = &ms, .pColorBlendState = &cb, .layout = layout };
	VkPipeline p;
	VkResult r = vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p);
	printf("%-4s graphics pipeline with heap descriptors loaded in a loop header (dh_loop_header.spv, VkResult %d)\n",
	       r ? "FAIL" : "OK", r);
	fails += r != VK_SUCCESS;
}

static uint32_t min32(uint32_t a, uint32_t b) { return a < b ? a : b; }

int main(int argc, char **argv)
{
	if (argc != 2) { fprintf(stderr, "usage: %s <spv dir>\n", argv[0]); return 2; }
	dir = argv[1];
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }

	VkPhysicalDeviceVulkan12Properties p12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES };
	VkPhysicalDeviceProperties2 p2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &p12 };
	vkGetPhysicalDeviceProperties2(pd, &p2);
	VkPhysicalDeviceVulkan12Features v12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES };
	VkPhysicalDeviceFeatures2 f2q = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v12 };
	vkGetPhysicalDeviceFeatures2(pd, &f2q);

	/* vkd3d_bindless_state_get_bindless_flags */
	int cbv_as_ssbo = p12.maxPerStageDescriptorUpdateAfterBindUniformBuffers < MAX_VIEWS ||
	                  !v12.descriptorBindingUniformBufferUpdateAfterBind || !v12.shaderUniformBufferArrayNonUniformIndexing;
	int raw_ssbo = p2.properties.limits.minStorageBufferOffsetAlignment <= 16;
	printf("     vkd3d-proton legacy bindless: CBV as %s, raw SSBO set %s\n", cbv_as_ssbo ? "SSBO" : "UBO", raw_ssbo ? "yes" : "no");
	if (!raw_ssbo) { printf("FAIL minStorageBufferOffsetAlignment %llu > 16\n", (unsigned long long)p2.properties.limits.minStorageBufferOffsetAlignment); return 1; }

	/* vkd3d-proton's device enables robustness2 (nullDescriptor for zero_initialize) and all supported features */
	VkPhysicalDeviceRobustness2FeaturesEXT rb2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
		.robustBufferAccess2 = VK_TRUE, .robustImageAccess2 = VK_TRUE, .nullDescriptor = VK_TRUE };
	v12.pNext = &rb2;
	VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, &v12, .dynamicRendering = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v13, .features = f2q.features };
	const char *exts[] = { VK_EXT_ROBUSTNESS_2_EXTENSION_NAME };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
		.enabledExtensionCount = 1, .ppEnabledExtensionNames = exts };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	/* vkd3d_bindless_state_init_legacy (sampler set first, then CBV, SRV buffer/image, UAV buffer/image, raw SSBO) */
	struct heap_set sampler[] = { { "sampler", VK_DESCRIPTOR_TYPE_SAMPLER, 0 } };
	struct heap_set views[VIEW_SETS] = {
		[CBV] =        { "cbv", cbv_as_ssbo ? VK_DESCRIPTOR_TYPE_STORAGE_BUFFER : VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, EXTRA_SSBOS },
		[SRV_BUFFER] = { "srv_buffer", VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 0 },
		[SRV_IMAGE] =  { "srv_image", VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 0 },
		[UAV_BUFFER] = { "uav_buffer", VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 0 },
		[UAV_IMAGE] =  { "uav_image", VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 0 },
		[RAW_SSBO] =   { "raw_ssbo", VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 0 },
	};
	/* d3d12_max_host_descriptor_count_from_heap_type */
	uint32_t host_views = min32(cbv_as_ssbo ? p12.maxDescriptorSetUpdateAfterBindStorageBuffers : p12.maxDescriptorSetUpdateAfterBindUniformBuffers,
	                            min32(p12.maxDescriptorSetUpdateAfterBindSampledImages,
	                                  min32(p12.maxDescriptorSetUpdateAfterBindStorageBuffers, p12.maxDescriptorSetUpdateAfterBindStorageImages)));
	uint32_t host_samplers = p12.maxDescriptorSetUpdateAfterBindSamplers;
	sampler[0].layout = heap_layout(VK_DESCRIPTOR_TYPE_SAMPLER, 0, MAX_SAMPLERS);
	sampler[0].host = heap_layout(VK_DESCRIPTOR_TYPE_SAMPLER, 0, host_samplers);
	for (uint32_t i = 0; i < VIEW_SETS; i++) {
		views[i].layout = heap_layout(views[i].type, views[i].extra, MAX_VIEWS);
		views[i].host = heap_layout(views[i].type, views[i].extra, host_views);
	}
	printf("OK   set layouts: %u view sets of %u (host %u), sampler set of %u (host %u)\n",
	       VIEW_SETS, MAX_VIEWS, host_views, MAX_SAMPLERS, host_samplers);

	/* 1. */
	VkDescriptorSet sets[VIEW_SETS];
	char what[96];
	static const uint32_t view_heaps[] = { 1, 64, 4096, 65536, 500000, MAX_VIEWS };
	for (uint32_t i = 0; i < sizeof(view_heaps) / sizeof(*view_heaps); i++) {
		snprintf(what, sizeof(what), "shader-visible CBV_SRV_UAV heap of %u", view_heaps[i]);
		heap(what, views, VIEW_SETS, view_heaps[i], 1, sets, 0);
		snprintf(what, sizeof(what), "host CBV_SRV_UAV heap of %u", view_heaps[i]);
		heap(what, views, VIEW_SETS, view_heaps[i], 0, sets, 0);
	}
	static const uint32_t sampler_heaps[] = { 1, 16, MAX_SAMPLERS };
	for (uint32_t i = 0; i < sizeof(sampler_heaps) / sizeof(*sampler_heaps); i++) {
		snprintf(what, sizeof(what), "shader-visible sampler heap of %u", sampler_heaps[i]);
		heap(what, sampler, 1, sampler_heaps[i], 1, sets, 0);
		snprintf(what, sizeof(what), "host sampler heap of %u", sampler_heaps[i]);
		heap(what, sampler, 1, sampler_heaps[i], 0, sets, 0);
	}
	static const uint32_t single[] = { 1, 63, 65536 };
	for (uint32_t i = 0; i < VIEW_SETS; i++)
		for (uint32_t j = 0; j < sizeof(single) / sizeof(*single); j++) {
			snprintf(what, sizeof(what), "pool of one %s set of %u", views[i].name, single[j]);
			heap(what, &views[i], 1, single[j], 1, sets, 0);
		}

	/* 2. */
	read_heap(views, queue);

	/* 3. */
	loop_header_pipeline(views, sampler);

	if (fails)
		printf("descriptor_heap: %d failure(s)\n", fails);
	return fails != 0;
}
