/*
 * Freeing memory once a timeline semaphore signalled, while the command buffer that signalled it
 * has not completed (DXVK frees its memory chunks this way; Heroes Olden Era lost the device with
 * kIOGPUCommandBufferCallbackErrorInvalidResource).
 *
 * MoltenVK signals timeline semaphores from the GPU (MTLSharedEvent) and, with a residency set, submits
 * command buffers that do not retain their resources. Each round submits a command buffer that copies
 * from a 32 MiB buffer (src) and signals the semaphore, then a long-running compute dispatch in the same
 * submission after the signal keeps the command buffer alive; the host waits for the semaphore value
 * and immediately destroys src and frees its memory, then waits for the queue. Run under Metal API
 * validation (run.sh): releasing src while the command buffer is alive fails validation ("being destroyed
 * while still required to be alive by the command buffer") or the queue reports device loss. The copied
 * data is checked too.
 * Then 10000 image views are created and destroyed in a burst while a command buffer runs; the time of
 * the destroy loop is printed (deferred releases are batched, not one marker per object).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static VkDevice dev;
static VkPhysicalDevice pd;

static uint32_t mem_type(uint32_t bits, VkMemoryPropertyFlags want)
{
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
			return i;
	return 0;
}

static VkBuffer buffer(VkDeviceSize size, VkBufferUsageFlags usage, VkDeviceMemory *mem, void **map)
{
	VkBufferCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage };
	VkBuffer b;
	CK(vkCreateBuffer(dev, &ci, NULL, &b));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, b, &mr);
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = mem_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
	CK(vkAllocateMemory(dev, &ai, NULL, mem));
	CK(vkBindBufferMemory(dev, b, *mem, 0));
	CK(vkMapMemory(dev, *mem, 0, VK_WHOLE_SIZE, 0, map));
	return b;
}

/* Busy loop: keeps the command buffer running for a while after the semaphore signal. */
static const uint32_t busy_spv[] = {
#include "busy.comp.inc"
};

int main(void)
{
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	VkPhysicalDeviceVulkan12Features v12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .timelineSemaphore = VK_TRUE };
	VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, &v12, .synchronization2 = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v13 };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	VkSemaphoreTypeCreateInfo stci = { VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO, .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE };
	VkSemaphoreCreateInfo sci = { VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, &stci };
	VkSemaphore sem;
	CK(vkCreateSemaphore(dev, &sci, NULL, &sem));

	VkShaderModuleCreateInfo smci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(busy_spv), .pCode = busy_spv };
	VkShaderModule busy;
	CK(vkCreateShaderModule(dev, &smci, NULL, &busy));
	VkDescriptorSetLayoutBinding b = { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL };
	VkDescriptorSetLayoutCreateInfo dslci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &b };
	VkDescriptorSetLayout dsl;
	CK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkComputePipelineCreateInfo cpci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = busy, .pName = "main" },
		.layout = layout };
	VkPipeline pipe;
	CK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe));
	VkDeviceMemory busy_mem;
	uint32_t *busy_map;
	VkBuffer busy_buf = buffer(4096, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, &busy_mem, (void **)&busy_map);
	VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
	VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps };
	VkDescriptorPool dpool;
	CK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));
	VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl };
	VkDescriptorSet set;
	CK(vkAllocateDescriptorSets(dev, &dsai, &set));
	VkDescriptorBufferInfo dbi = { busy_buf, 0, VK_WHOLE_SIZE };
	VkWriteDescriptorSet w = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .descriptorCount = 1,
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi };
	vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);

	VkCommandPoolCreateInfo cpi = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &cpi, NULL, &pool));
	VkCommandBuffer cmd[2];
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 2 };
	CK(vkAllocateCommandBuffers(dev, &cai, cmd));

	const VkDeviceSize size = 32u << 20;
	VkDeviceMemory dst_mem;
	uint32_t *dst_map;
	VkBuffer dst = buffer(4096, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &dst_mem, (void **)&dst_map);
	int fails = 0;
	uint64_t value = 0;
	for (uint32_t round = 0; round < 8; round++) {
		VkDeviceMemory src_mem;
		uint32_t *src_map;
		VkBuffer src = buffer(size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &src_mem, (void **)&src_map);
		src_map[0] = 0x1000 + round;
		VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
		CK(vkResetCommandBuffer(cmd[0], 0));
		CK(vkBeginCommandBuffer(cmd[0], &bi));
		VkBufferCopy region = { 0, 0, 4 };
		vkCmdCopyBuffer(cmd[0], src, dst, 1, &region);
		CK(vkEndCommandBuffer(cmd[0]));
		CK(vkResetCommandBuffer(cmd[1], 0));
		CK(vkBeginCommandBuffer(cmd[1], &bi));
		vkCmdBindPipeline(cmd[1], VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
		vkCmdBindDescriptorSets(cmd[1], VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
		vkCmdDispatch(cmd[1], 64, 1, 1);
		CK(vkEndCommandBuffer(cmd[1]));
		/* Submission 1: copy, then signal. Submission 2 (same vkQueueSubmit): long dispatch. MoltenVK
		 * encodes both in one MTLCommandBuffer, so it completes after the signal. */
		value++;
		VkTimelineSemaphoreSubmitInfo tsi = { VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
			.signalSemaphoreValueCount = 1, .pSignalSemaphoreValues = &value };
		VkSubmitInfo si[2] = {
			{ VK_STRUCTURE_TYPE_SUBMIT_INFO, &tsi, .commandBufferCount = 1, .pCommandBuffers = &cmd[0],
			  .signalSemaphoreCount = 1, .pSignalSemaphores = &sem },
			{ VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd[1] },
		};
		CK(vkQueueSubmit(queue, 2, si, VK_NULL_HANDLE));
		VkSemaphoreWaitInfo wi = { VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO, .semaphoreCount = 1, .pSemaphores = &sem,
			.pValues = &value };
		CK(vkWaitSemaphores(dev, &wi, UINT64_MAX));
		/* Valid: the copy that used src completed before the signal. */
		vkDestroyBuffer(dev, src, NULL);
		vkFreeMemory(dev, src_mem, NULL);
		VkResult r = vkQueueWaitIdle(queue);
		int ok = r == VK_SUCCESS && dst_map[0] == 0x1000 + round;
		if (!ok) printf("FAIL round %u: vkQueueWaitIdle %d, copied 0x%x\n", round, r, dst_map[0]);
		fails += !ok;
	}
	printf("%-4s free after timeline semaphore signal, command buffer still running: 8 rounds\n", fails ? "FAIL" : "OK");

	/* Burst: destroy 10000 image views while a long dispatch is in flight. */
	{
		VkImageCreateInfo ici2 = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
			.format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { 64, 64, 1 }, .mipLevels = 1, .arrayLayers = 1,
			.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_SAMPLED_BIT,
			.flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT };
		VkImage img;
		CK(vkCreateImage(dev, &ici2, NULL, &img));
		VkMemoryRequirements imr;
		vkGetImageMemoryRequirements(dev, img, &imr);
		VkMemoryAllocateInfo iai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = imr.size,
			.memoryTypeIndex = mem_type(imr.memoryTypeBits, 0) };
		VkDeviceMemory imem;
		CK(vkAllocateMemory(dev, &iai, NULL, &imem));
		CK(vkBindImageMemory(dev, img, imem, 0));
		enum { N = 10000 };
		VkImageView *views = malloc(N * sizeof(VkImageView));
		VkDescriptorSetLayoutBinding ib = { 0, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL };
		VkDescriptorSetLayoutCreateInfo idslci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &ib };
		VkDescriptorSetLayout idsl;
		CK(vkCreateDescriptorSetLayout(dev, &idslci, NULL, &idsl));
		VkDescriptorPoolSize ips = { VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1 };
		VkDescriptorPoolCreateInfo idpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ips };
		VkDescriptorPool idpool;
		CK(vkCreateDescriptorPool(dev, &idpci, NULL, &idpool));
		VkDescriptorSetAllocateInfo idsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = idpool, .descriptorSetCount = 1, .pSetLayouts = &idsl };
		VkDescriptorSet iset;
		CK(vkAllocateDescriptorSets(dev, &idsai, &iset));
		for (uint32_t i = 0; i < N; i++) {
			/* A format different from the image's, so every view owns a Metal texture view. */
			VkImageViewCreateInfo vci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img,
				.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_SRGB,
				.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
			CK(vkCreateImageView(dev, &vci, NULL, &views[i]));
			/* Metal texture views are created lazily; writing a descriptor creates it. */
			VkDescriptorImageInfo dii = { VK_NULL_HANDLE, views[i], VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
			VkWriteDescriptorSet iw = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = iset, .descriptorCount = 1,
				.descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .pImageInfo = &dii };
			vkUpdateDescriptorSets(dev, 1, &iw, 0, NULL);
		}
		VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
		CK(vkResetCommandBuffer(cmd[1], 0));
		CK(vkBeginCommandBuffer(cmd[1], &bi));
		vkCmdBindPipeline(cmd[1], VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
		vkCmdBindDescriptorSets(cmd[1], VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
		vkCmdDispatch(cmd[1], 64, 1, 1);
		CK(vkEndCommandBuffer(cmd[1]));
		VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd[1] };
		CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
		struct timespec t0, t1, t2;
		clock_gettime(CLOCK_MONOTONIC, &t0);
		for (uint32_t i = 0; i < N; i++)
			vkDestroyImageView(dev, views[i], NULL);
		clock_gettime(CLOCK_MONOTONIC, &t1);
		VkResult r = vkQueueWaitIdle(queue);
		clock_gettime(CLOCK_MONOTONIC, &t2);
		double destroy_ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
		double idle_ms = (t2.tv_sec - t1.tv_sec) * 1e3 + (t2.tv_nsec - t1.tv_nsec) / 1e6;
		printf("%-4s destroyed %d image views in %.2f ms during a dispatch (queue idle %.2f ms later, VkResult %d)\n",
		       r == VK_SUCCESS ? "OK" : "FAIL", N, destroy_ms, idle_ms, r);
		fails += r != VK_SUCCESS;
		free(views);
		vkDestroyDescriptorPool(dev, idpool, NULL);
		vkDestroyDescriptorSetLayout(dev, idsl, NULL);
		vkDestroyImage(dev, img, NULL);
		vkFreeMemory(dev, imem, NULL);
	}
	vkDestroyDevice(dev, NULL);
	printf("%-4s device destroyed with pending releases\n", "OK");
	return fails != 0;
}
