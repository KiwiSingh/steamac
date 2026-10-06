/*
 * Texel buffer views at offsets that are not a multiple of 16 bytes (Metal's texture buffer alignment).
 * vkd3d-proton requires single texel alignment (storage/uniformTexelBufferOffsetSingleTexelAlignment); MoltenVK
 * emulates it: the Metal texture starts at the 16-byte aligned offset below the view, and the shader adds the
 * remaining texels, which come from the aux (buffer size) buffer of argument buffer descriptor sets, or from an
 * implicit buffer for sets bound without argument buffers (push descriptors).
 *
 * Source buffer: byte i = i. word(b) = little-endian uint of bytes b..b+3. Robustness2 enabled.
 * 1. tb_read.comp, argument buffer set:
 *      R32_UINT view at 4 (8 texels), R8_UINT view at 3 (10 texels), RGBA8_UINT view at 8, storage R32_UINT view at
 *      byte 20 of a buffer of words 1000 + i (load, store, atomic add, size), an array of R32_UINT views at 68, 72,
 *      76 written one element per update, an array of storage buffers of 16..64 bytes written one element per
 *      update (arrayLength: their sizes are in the same aux buffer), reads past the end of views (bounds of the view,
 *      not of the Metal texture that starts before it): zero, with component substitution for the format, so (0, 0,
 *      0, 0) for RGBA8 (robustBufferAccess2); MoltenVK returns (0, 0, 0, 1).
 * 2. tb_bindless.comp: variable-count update-after-bind array (vkd3d-proton's heaps): element 5 written at 12,
 *    element 6 copied from it with VkCopyDescriptorSet.
 * 3. tb_push.comp: push descriptor set, R32_UINT view at 8; the 256-byte output buffer is written (small buffers with
 *    robustBufferAccess2 were replaced by a temporary copy that lost the writes).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static VkDevice dev;
static VkPhysicalDevice pd;
static VkQueue queue;
static VkCommandPool pool;
static const char *dir;
static int fails;

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

static VkBufferView view(VkBuffer buf, VkFormat format, VkDeviceSize offset, VkDeviceSize range)
{
	VkBufferViewCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO, .buffer = buf, .format = format,
		.offset = offset, .range = range };
	VkBufferView v;
	CK(vkCreateBufferView(dev, &ci, NULL, &v));
	return v;
}

static VkPipeline compute(const char *spv, uint32_t set_count, const VkDescriptorSetLayout *sets, VkPipelineLayout *layout)
{
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = set_count, .pSetLayouts = sets };
	CK(vkCreatePipelineLayout(dev, &plci, NULL, layout));
	VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
		           .module = module(spv), .pName = "main" }, .layout = *layout };
	VkPipeline p;
	VkResult r = vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p);
	printf("%-4s create %s (VkResult %d)\n", r ? "FAIL" : "OK", spv, r);
	if (r) exit(1);
	return p;
}

static VkCommandBuffer begin(void)
{
	VkCommandBufferAllocateInfo ai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &ai, &cmd));
	VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	CK(vkBeginCommandBuffer(cmd, &bi));
	return cmd;
}

static void submit(VkCommandBuffer cmd)
{
	VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));
}

static uint32_t word(uint32_t b)
{
	return b | (b + 1) << 8 | (b + 2) << 16 | (b + 3) << 24;
}

static void expect(const char *what, const uint32_t *got, const uint32_t *want, uint32_t count)
{
	uint32_t bad = 0;
	for (uint32_t i = 0; i < count; i++)
		if (got[i] != want[i]) {
			if (!bad)
				printf("     %s: [%u] = 0x%08x, want 0x%08x\n", what, i, got[i], want[i]);
			bad++;
		}
	printf("%-4s %s (%u values, %u wrong)\n", bad ? "FAIL" : "OK", what, count, bad);
	fails += bad != 0;
}

static VkDescriptorSetLayout set_layout(const VkDescriptorSetLayoutBinding *b, uint32_t n, const VkDescriptorBindingFlags *flags,
                                        VkDescriptorSetLayoutCreateFlags create_flags)
{
	VkDescriptorSetLayoutBindingFlagsCreateInfo fci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		.bindingCount = n, .pBindingFlags = flags };
	VkDescriptorSetLayoutCreateInfo ci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, flags ? &fci : NULL,
		.flags = create_flags, .bindingCount = n, .pBindings = b };
	VkDescriptorSetLayout l;
	CK(vkCreateDescriptorSetLayout(dev, &ci, NULL, &l));
	return l;
}

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

	VkPhysicalDeviceDriverProperties drv = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
	VkPhysicalDeviceVulkan13Properties p13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_PROPERTIES, &drv };
	VkPhysicalDeviceProperties2 p2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &p13 };
	vkGetPhysicalDeviceProperties2(pd, &p2);
	printf("%-4s single texel alignment: storage %u (%llu bytes), uniform %u (%llu bytes)\n",
	       p13.storageTexelBufferOffsetSingleTexelAlignment && p13.uniformTexelBufferOffsetSingleTexelAlignment ? "OK" : "FAIL",
	       p13.storageTexelBufferOffsetSingleTexelAlignment, (unsigned long long)p13.storageTexelBufferOffsetAlignmentBytes,
	       p13.uniformTexelBufferOffsetSingleTexelAlignment, (unsigned long long)p13.uniformTexelBufferOffsetAlignmentBytes);
	if (!p13.storageTexelBufferOffsetSingleTexelAlignment || !p13.uniformTexelBufferOffsetSingleTexelAlignment) return 1;

	VkPhysicalDeviceRobustness2FeaturesEXT rb2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
		.robustBufferAccess2 = VK_TRUE, .robustImageAccess2 = VK_TRUE };
	VkPhysicalDeviceVulkan12Features v12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &rb2,
		.descriptorIndexing = VK_TRUE, .runtimeDescriptorArray = VK_TRUE, .descriptorBindingVariableDescriptorCount = VK_TRUE,
		.descriptorBindingPartiallyBound = VK_TRUE, .descriptorBindingUniformTexelBufferUpdateAfterBind = VK_TRUE,
		.shaderUniformTexelBufferArrayDynamicIndexing = VK_TRUE, .shaderUniformTexelBufferArrayNonUniformIndexing = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v12,
		.features = { .robustBufferAccess = VK_TRUE, .shaderStorageBufferArrayDynamicIndexing = VK_TRUE } };
	const char *exts[] = { VK_EXT_ROBUSTNESS_2_EXTENSION_NAME, VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
		.enabledExtensionCount = 2, .ppEnabledExtensionNames = exts };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	vkGetDeviceQueue(dev, 0, 0, &queue);
	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));

	const VkBufferUsageFlags texel = VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT | VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT;
	uint8_t *src;
	uint32_t *wb, *sb, *out;
	VkBuffer srcbuf = buffer(256, texel, (void **)&src);
	VkBuffer wbuf = buffer(256, texel, (void **)&wb);
	VkBuffer sbuf = buffer(256, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, (void **)&sb);
	VkBuffer obuf = buffer(256, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, (void **)&out);
	for (uint32_t i = 0; i < 256; i++)
		src[i] = (uint8_t)i;
	for (uint32_t i = 0; i < 64; i++)
		wb[i] = 1000 + i;

	VkDescriptorPoolSize sizes[] = { { VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 32 }, { VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 4 },
	                                 { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 16 } };
	VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .flags = VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT,
		.maxSets = 4, .poolSizeCount = 3, .pPoolSizes = sizes };
	VkDescriptorPool dpool;
	CK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));

	/* 1. tb_read.comp */
	{
		VkDescriptorSetLayoutBinding b[] = {
			{ 0, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
			{ 1, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
			{ 2, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
			{ 3, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
			{ 4, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 4, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
			{ 5, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 4, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
			{ 6, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
		};
		VkDescriptorBindingFlags flags[7] = { [4] = VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT };
		VkDescriptorSetLayout dsl = set_layout(b, 7, flags, 0);
		VkPipelineLayout layout;
		VkPipeline p = compute("tb_read.comp.spv", 1, &dsl, &layout);
		VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dpool,
			.descriptorSetCount = 1, .pSetLayouts = &dsl };
		VkDescriptorSet set;
		CK(vkAllocateDescriptorSets(dev, &dsai, &set));
		VkBufferView views[4] = { view(srcbuf, VK_FORMAT_R32_UINT, 4, 32), view(srcbuf, VK_FORMAT_R8_UINT, 3, 10),
		                          view(srcbuf, VK_FORMAT_R8G8B8A8_UINT, 8, 16), view(wbuf, VK_FORMAT_R32_UINT, 20, 40) };
		for (uint32_t i = 0; i < 4; i++) {
			VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = i, .descriptorCount = 1,
				.descriptorType = i == 3 ? VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER : VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER,
				.pTexelBufferView = &views[i] };
			vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);
		}
		for (uint32_t i = 1; i < 4; i++) {
			VkBufferView v = view(srcbuf, VK_FORMAT_R32_UINT, 64 + 4 * i, 16);
			VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 4, .dstArrayElement = i,
				.descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .pTexelBufferView = &v };
			vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);
		}
		for (uint32_t i = 0; i < 4; i++) {
			VkDescriptorBufferInfo bi = { sbuf, 0, 16 * (i + 1) };
			VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 5, .dstArrayElement = i,
				.descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &bi };
			vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);
		}
		VkDescriptorBufferInfo obi = { obuf, 0, VK_WHOLE_SIZE };
		VkWriteDescriptorSet ow = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 6, .descriptorCount = 1,
			.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &obi };
		vkUpdateDescriptorSets(dev, 1, &ow, 0, NULL);

		memset(out, 0xcd, 256);
		VkCommandBuffer cmd = begin();
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p);
		vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
		vkCmdDispatch(cmd, 1, 1, 1);
		submit(cmd);

		uint32_t want[34];
		for (uint32_t k = 0; k < 8; k++)
			want[k] = word(4 + 4 * k);
		want[8] = 8;
		for (uint32_t k = 0; k < 10; k++)
			want[9 + k] = 3 + k;
		want[19] = 10;
		want[20] = word(12);
		want[21] = 4;
		expect("uniform texel buffers at 4 (R32), 3 (R8), 8 (RGBA8): texels and sizes", out, want, 22);
		want[22] = 1007;
		want[23] = 1009;
		want[24] = 10;
		expect("storage texel buffer at 20 (R32): load, old value of atomic add, size", out + 22, want + 22, 3);
		uint32_t wwant[16];
		for (uint32_t i = 0; i < 16; i++)
			wwant[i] = 1000 + i;
		wwant[8] = 0xabcd0003u;
		wwant[9] = 1009 + 0x100;
		expect("storage texel buffer at 20: store and atomic at their words, other words untouched", wb, wwant, 16);
		for (uint32_t i = 1; i < 4; i++)
			want[24 + i] = word(64 + 4 * i);
		expect("array of texel buffers at 68, 72, 76 written one element per update", out + 25, want + 25, 3);
		for (uint32_t i = 0; i < 4; i++)
			want[28 + i] = 4 * (i + 1);
		expect("array of storage buffers written one element per update: arrayLength 4, 8, 12, 16", out + 28, want + 28, 4);
		want[32] = 0;
		want[33] = drv.driverID == VK_DRIVER_ID_MOLTENVK;
		expect(want[33] ? "texels past the end of views at 4 (R32, texel 8) and 8 (RGBA8, texel 4): x 0, alpha 1 (MoltenVK)"
		                : "texels past the end of views at 4 (R32, texel 8) and 8 (RGBA8, texel 4): x 0, alpha 0",
		       out + 32, want + 32, 2);
	}

	/* 2. tb_bindless.comp */
	{
		VkDescriptorSetLayoutBinding ob = { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL };
		VkDescriptorSetLayoutBinding hb = { 0, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 16, VK_SHADER_STAGE_COMPUTE_BIT, NULL };
		VkDescriptorBindingFlags hflags = VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT | VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT |
		                                  VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT;
		VkDescriptorSetLayout dsl[2] = { set_layout(&ob, 1, NULL, 0),
		                                 set_layout(&hb, 1, &hflags, VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT) };
		VkPipelineLayout layout;
		VkPipeline p = compute("tb_bindless.comp.spv", 2, dsl, &layout);
		uint32_t var = 8;
		VkDescriptorSetVariableDescriptorCountAllocateInfo vai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
			.descriptorSetCount = 2, .pDescriptorCounts = (uint32_t[]){ 0, var } };
		VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, &vai, .descriptorPool = dpool,
			.descriptorSetCount = 2, .pSetLayouts = dsl };
		VkDescriptorSet sets[2];
		CK(vkAllocateDescriptorSets(dev, &dsai, sets));
		VkDescriptorBufferInfo obi = { obuf, 0, VK_WHOLE_SIZE };
		VkBufferView v = view(srcbuf, VK_FORMAT_R32_UINT, 12, 16);
		VkWriteDescriptorSet w[2] = {
			{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = sets[0], .dstBinding = 0, .descriptorCount = 1,
			  .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &obi },
			{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = sets[1], .dstBinding = 0, .dstArrayElement = 5, .descriptorCount = 1,
			  .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .pTexelBufferView = &v },
		};
		VkCopyDescriptorSet c = { VK_STRUCTURE_TYPE_COPY_DESCRIPTOR_SET, .srcSet = sets[1], .srcBinding = 0, .srcArrayElement = 5,
			.dstSet = sets[1], .dstBinding = 0, .dstArrayElement = 6, .descriptorCount = 1 };
		vkUpdateDescriptorSets(dev, 2, w, 0, NULL);
		vkUpdateDescriptorSets(dev, 0, NULL, 1, &c);

		memset(out, 0xcd, 256);
		VkCommandBuffer cmd = begin();
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p);
		vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 2, sets, 0, NULL);
		vkCmdDispatch(cmd, 1, 1, 1);
		submit(cmd);
		uint32_t want[4] = { word(12), 4, word(16), 4 };
		expect("variable-count update-after-bind array: view at 12 in element 5, copied to element 6", out, want, 4);
	}

	/* 3. tb_push.comp */
	{
		VkDescriptorSetLayoutBinding b[] = {
			{ 0, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
			{ 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
		};
		VkDescriptorSetLayout dsl = set_layout(b, 2, NULL, VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT);
		VkPipelineLayout layout;
		VkPipeline p = compute("tb_push.comp.spv", 1, &dsl, &layout);
		PFN_vkCmdPushDescriptorSetKHR push = (PFN_vkCmdPushDescriptorSetKHR)vkGetDeviceProcAddr(dev, "vkCmdPushDescriptorSetKHR");
		VkBufferView v = view(srcbuf, VK_FORMAT_R32_UINT, 8, 16);
		VkDescriptorBufferInfo obi = { obuf, 0, VK_WHOLE_SIZE };
		VkWriteDescriptorSet w[2] = {
			{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 0, .descriptorCount = 1,
			  .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .pTexelBufferView = &v },
			{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 1, .descriptorCount = 1,
			  .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &obi },
		};
		memset(out, 0xcd, 256);
		VkCommandBuffer cmd = begin();
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p);
		push(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 2, w);
		vkCmdDispatch(cmd, 1, 1, 1);
		submit(cmd);
		uint32_t want[3] = { word(8), word(16), 4 };
		expect("push descriptor set: view at 8", out, want, 3);
	}

	if (fails) { printf("texel_buffer: %d failure(s)\n", fails); return 1; }
	return 0;
}
