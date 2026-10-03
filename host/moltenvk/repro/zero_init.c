/*
 * Zero initialization of workgroup memory (VK_KHR_zero_initialize_workgroup_memory, required by
 * DXVK): shared variables with OpConstantNull initializers. SPIRV-Cross strides the cooperative
 * initialization by gl_WorkGroupSize, which was not declared unless the shader itself used it
 * ("use of undeclared identifier 'gl_WorkGroupSize'", 29 DXVK compute pipelines in Death's Door).
 *
 * zi_dirty.comp fills workgroup memory with a non-zero pattern first, then each of these dispatches
 * one workgroup and copies its zero-initialized shared variables out; every value must be 0. (On Apple
 * GPUs threadgroup memory of a new dispatch has read as zero even without the initialization, so the
 * readback checks that the pipelines compile and produce zeros, not that the initialization itself ran.)
 *   zi_lit.comp   literal local_size_x = 64, uint[100] + struct array (DXVK's g0/g1 pattern)
 *   zi_spec.comp  local_size_x_id spec constant, specialized to 32
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static VkDevice dev;
static VkPhysicalDevice pd;
static const char *dir;

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
	VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		.shaderZeroInitializeWorkgroupMemory = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v13 };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	VkDescriptorSetLayoutBinding b = { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL };
	VkDescriptorSetLayoutCreateInfo dslci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &b };
	VkDescriptorSetLayout dsl;
	CK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));

	const VkDeviceSize size = 4 * 1024 * 4;		/* 4 workgroups x 1024 uints, workgroup w writes at w * 1024 */
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
	VkBuffer buf;
	CK(vkCreateBuffer(dev, &bci, NULL, &buf));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, buf, &mr);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	uint32_t t = 0;
	while (!(mr.memoryTypeBits & (1u << t)) ||
	       (mp.memoryTypes[t].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) !=
	           (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))
		t++;
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = t };
	VkDeviceMemory mem;
	CK(vkAllocateMemory(dev, &mai, NULL, &mem));
	CK(vkBindBufferMemory(dev, buf, mem, 0));
	uint32_t *map;
	CK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, (void **)&map));

	VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
	VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps };
	VkDescriptorPool dpool;
	CK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));
	VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dpool,
		.descriptorSetCount = 1, .pSetLayouts = &dsl };
	VkDescriptorSet set;
	CK(vkAllocateDescriptorSets(dev, &dsai, &set));
	VkDescriptorBufferInfo dbi = { buf, 0, VK_WHOLE_SIZE };
	VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .descriptorCount = 1,
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi };
	vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);

	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));

	struct { const char *spv; uint32_t spec_wg; uint32_t count; } tests[] = {
		{ "zi_lit.comp.spv", 0, 133 },
		{ "zi_spec.comp.spv", 32, 107 },
	};
	VkPipeline dirty;
	{
		VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
			.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
			           .module = module("zi_dirty.comp.spv"), .pName = "main" }, .layout = layout };
		CK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &dirty));
	}
	int fails = 0;
	for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++) {
		VkSpecializationMapEntry me = { 0, 0, 4 };
		VkSpecializationInfo si = { 1, &me, 4, &tests[i].spec_wg };
		VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
			.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
			           .module = module(tests[i].spv), .pName = "main",
			           .pSpecializationInfo = tests[i].spec_wg ? &si : NULL }, .layout = layout };
		VkPipeline p;
		VkResult r = vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p);
		printf("%-4s create %s (VkResult %d)\n", r == VK_SUCCESS ? "OK" : "FAIL", tests[i].spv, r);
		if (r) { fails++; continue; }
		memset(map, 0xab, size);
		VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 1 };
		VkCommandBuffer cmd;
		CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
		VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
		CK(vkBeginCommandBuffer(cmd, &cbbi));
		vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
		VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
			.dstAccessMask = VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_HOST_READ_BIT };
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, dirty);
		vkCmdDispatch(cmd, 8, 1, 1);
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p);
		vkCmdDispatch(cmd, 1, 1, 1);
		vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
		CK(vkEndCommandBuffer(cmd));
		VkSubmitInfo sinfo = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
		CK(vkQueueSubmit(queue, 1, &sinfo, VK_NULL_HANDLE));
		CK(vkQueueWaitIdle(queue));
		uint32_t bad = 0, first_bad = 0;
		for (uint32_t k = 0; k < tests[i].count; k++)
			if (map[k] != 0) { if (!bad) first_bad = k; bad++; }
		printf("%-4s %s: %u zero-initialized values read back, %u non-zero (first at %u: 0x%08x)\n", bad ? "FAIL" : "OK",
		       tests[i].spv, tests[i].count, bad, first_bad, map[first_bad]);
		fails += bad != 0;
	}
	if (fails) { printf("zero_init: %d failure(s)\n", fails); return 1; }
	return 0;
}
