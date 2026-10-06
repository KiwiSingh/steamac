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
 * Heaps of the sizes games create (Stellar Blade, UE4: CBV_SRV_UAV shader-visible heaps up to 1000000, samplers
 * 2048, many small host heaps). A failed allocation is fatal over Venus: the guest allocates sets asynchronously,
 * the host's VK_ERROR_OUT_OF_POOL_MEMORY leaves a set handle the next vkUpdateDescriptorSets cannot find, and the
 * context's command stream stops (the game hangs on its first frame).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

enum { MAX_VIEWS = 1000000, MAX_SAMPLERS = 2048, EXTRA_SSBOS = 2 };

static VkDevice dev;
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

/* d3d12_descriptor_heap_create_descriptor_pool + _create_descriptor_set for each set of the heap's type. */
static void heap(const char *what, struct heap_set *sets, uint32_t set_count, uint32_t num_descriptors, int shader_visible)
{
	VkDescriptorPoolSize sizes[8];
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
		return;
	}
	char failed[256] = "";
	for (uint32_t i = 0; i < set_count; i++) {
		VkDescriptorSetVariableDescriptorCountAllocateInfo vci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
			.descriptorSetCount = 1, .pDescriptorCounts = &num_descriptors };
		VkDescriptorSetAllocateInfo ai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, &vci, .descriptorPool = pool,
			.descriptorSetCount = 1, .pSetLayouts = shader_visible ? &sets[i].layout : &sets[i].host };
		VkDescriptorSet set;
		r = vkAllocateDescriptorSets(dev, &ai, &set);
		if (r) {
			snprintf(failed + strlen(failed), sizeof(failed) - strlen(failed), " %s=%d", sets[i].name, r);
			continue;
		}
		zero_initialize(set, sets[i].type, sets[i].extra, num_descriptors);
	}
	printf("%-4s %s: %u sets of %u descriptors allocated%s%s\n", failed[0] ? "FAIL" : "OK", what, set_count, num_descriptors,
	       failed[0] ? ", failed:" : "", failed);
	fails += failed[0] != 0;
	vkDestroyDescriptorPool(dev, pool, NULL);
}

static uint32_t min32(uint32_t a, uint32_t b) { return a < b ? a : b; }

int main(void)
{
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }

	VkPhysicalDeviceVulkan12Properties p12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES };
	VkPhysicalDeviceProperties2 p2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &p12 };
	vkGetPhysicalDeviceProperties2(pd, &p2);
	VkPhysicalDeviceRobustness2FeaturesEXT rb2q = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT };
	VkPhysicalDeviceVulkan12Features v12q = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &rb2q };
	VkPhysicalDeviceFeatures2 f2q = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v12q };
	vkGetPhysicalDeviceFeatures2(pd, &f2q);

	/* vkd3d_bindless_state_get_bindless_flags */
	int cbv_as_ssbo = p12.maxPerStageDescriptorUpdateAfterBindUniformBuffers < MAX_VIEWS ||
	                  !v12q.descriptorBindingUniformBufferUpdateAfterBind || !v12q.shaderUniformBufferArrayNonUniformIndexing;
	int raw_ssbo = p2.properties.limits.minStorageBufferOffsetAlignment <= 16;
	printf("     vkd3d-proton legacy bindless: CBV as %s, raw SSBO set %s\n", cbv_as_ssbo ? "SSBO" : "UBO", raw_ssbo ? "yes" : "no");

	VkPhysicalDeviceRobustness2FeaturesEXT rb2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
		.robustBufferAccess2 = VK_TRUE, .robustImageAccess2 = VK_TRUE, .nullDescriptor = VK_TRUE };
	VkPhysicalDeviceVulkan12Features v12 = v12q;
	v12.pNext = &rb2;
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v12, .features = f2q.features };
	const char *exts[] = { VK_EXT_ROBUSTNESS_2_EXTENSION_NAME };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
		.enabledExtensionCount = 1, .ppEnabledExtensionNames = exts };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));

	/* vkd3d_bindless_state_init_legacy (sampler set first, then CBV, SRV buffer/image, UAV buffer/image, raw SSBO) */
	struct heap_set sampler[] = { { "sampler", VK_DESCRIPTOR_TYPE_SAMPLER, 0 } };
	struct heap_set views[6] = {
		{ "cbv", cbv_as_ssbo ? VK_DESCRIPTOR_TYPE_STORAGE_BUFFER : VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, EXTRA_SSBOS },
		{ "srv_buffer", VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 0 },
		{ "srv_image", VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 0 },
		{ "uav_buffer", VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 0 },
		{ "uav_image", VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 0 },
		{ "raw_ssbo", VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 0 },
	};
	uint32_t view_sets = raw_ssbo ? 6 : 5;
	/* d3d12_max_host_descriptor_count_from_heap_type */
	uint32_t host_views = min32(cbv_as_ssbo ? p12.maxDescriptorSetUpdateAfterBindStorageBuffers : p12.maxDescriptorSetUpdateAfterBindUniformBuffers,
	                            min32(p12.maxDescriptorSetUpdateAfterBindSampledImages,
	                                  min32(p12.maxDescriptorSetUpdateAfterBindStorageBuffers, p12.maxDescriptorSetUpdateAfterBindStorageImages)));
	uint32_t host_samplers = p12.maxDescriptorSetUpdateAfterBindSamplers;
	sampler[0].layout = heap_layout(VK_DESCRIPTOR_TYPE_SAMPLER, 0, MAX_SAMPLERS);
	sampler[0].host = heap_layout(VK_DESCRIPTOR_TYPE_SAMPLER, 0, host_samplers);
	for (uint32_t i = 0; i < view_sets; i++) {
		views[i].layout = heap_layout(views[i].type, views[i].extra, MAX_VIEWS);
		views[i].host = heap_layout(views[i].type, views[i].extra, host_views);
	}
	printf("OK   set layouts: %u view sets of %u (host %u), sampler set of %u (host %u)\n",
	       view_sets, MAX_VIEWS, host_views, MAX_SAMPLERS, host_samplers);

	static const uint32_t view_heaps[] = { 1, 64, 4096, 65536, 500000, MAX_VIEWS };
	for (uint32_t i = 0; i < sizeof(view_heaps) / sizeof(*view_heaps); i++) {
		char what[96];
		snprintf(what, sizeof(what), "shader-visible CBV_SRV_UAV heap of %u", view_heaps[i]);
		heap(what, views, view_sets, view_heaps[i], 1);
		snprintf(what, sizeof(what), "host CBV_SRV_UAV heap of %u", view_heaps[i]);
		heap(what, views, view_sets, view_heaps[i], 0);
	}
	static const uint32_t sampler_heaps[] = { 1, 16, MAX_SAMPLERS };
	for (uint32_t i = 0; i < sizeof(sampler_heaps) / sizeof(*sampler_heaps); i++) {
		char what[96];
		snprintf(what, sizeof(what), "shader-visible sampler heap of %u", sampler_heaps[i]);
		heap(what, sampler, 1, sampler_heaps[i], 1);
		snprintf(what, sizeof(what), "host sampler heap of %u", sampler_heaps[i]);
		heap(what, sampler, 1, sampler_heaps[i], 0);
	}

	if (fails)
		printf("descriptor_heap: %d failure(s)\n", fails);
	return fails != 0;
}
