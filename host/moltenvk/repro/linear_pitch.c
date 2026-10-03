/*
 * Linear images with an explicit row pitch, as virglrenderer creates them for dma-bufs.
 *
 * Venus' X11 WSI exports LINEAR buffers whose row pitch is aligned to 256 bytes (300 px BGRA ->
 * 1280). Xwayland/zink imports them with VkImageDrmFormatModifierExplicitCreateInfoEXT
 * { LINEAR, rowPitch 1280 }; virglrenderer turns that into a host VK_IMAGE_TILING_LINEAR image with
 * the explicit-info struct still chained and verifies the resulting layout. MoltenVK used to pick
 * its own pitch (1200), so virglrenderer refused the image and the swapchain failed.
 *
 * Checks for a 300x16 B8G8R8A8 LINEAR image with rowPitch 1280:
 *   - vkGetImageSubresourceLayout and vkGetDeviceImageSubresourceLayout report rowPitch 1280,
 *   - memory requirements cover 16 rows of 1280 bytes,
 *   - rows written through mapped memory at that pitch are what vkCmdCopyImageToBuffer reads,
 *   - a row pitch that is too small is rejected with VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static VkPhysicalDeviceMemoryProperties mp;

static uint32_t mem_type(uint32_t bits, VkMemoryPropertyFlags want) {
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
			return i;
	return UINT32_MAX;
}

int main(void) {
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	const char *dext[] = { VK_KHR_MAINTENANCE_5_EXTENSION_NAME };
	VkPhysicalDeviceMaintenance5FeaturesKHR m5 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_5_FEATURES_KHR,
		.maintenance5 = VK_TRUE };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1,
		.pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &m5, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci, .enabledExtensionCount = 1, .ppEnabledExtensionNames = dext };
	VkDevice dev;
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue q;
	vkGetDeviceQueue(dev, 0, 0, &q);
	PFN_vkGetDeviceImageSubresourceLayoutKHR getDeviceImageSubresourceLayout =
		(PFN_vkGetDeviceImageSubresourceLayoutKHR)vkGetDeviceProcAddr(dev, "vkGetDeviceImageSubresourceLayoutKHR");

	const uint32_t W = 300, H = 16, PITCH = 1280;
	int fails = 0;

	VkSubresourceLayout plane = { .offset = 0, .rowPitch = PITCH };
	VkImageDrmFormatModifierExplicitCreateInfoEXT explicit_info = {
		VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT, .drmFormatModifier = 0 /* LINEAR */,
		.drmFormatModifierPlaneCount = 1, .pPlaneLayouts = &plane };
	VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, &explicit_info, .imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_B8G8R8A8_UNORM, .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_LINEAR,
		.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
		.initialLayout = VK_IMAGE_LAYOUT_PREINITIALIZED };

	/* Layout before creating the image (virglrenderer verifies with this). */
	VkImageSubresource2KHR sub2 = { VK_STRUCTURE_TYPE_IMAGE_SUBRESOURCE_2_KHR, .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0 } };
	VkDeviceImageSubresourceInfoKHR dsi = { VK_STRUCTURE_TYPE_DEVICE_IMAGE_SUBRESOURCE_INFO_KHR, .pCreateInfo = &ci,
		.pSubresource = &sub2 };
	VkSubresourceLayout2KHR dl = { VK_STRUCTURE_TYPE_SUBRESOURCE_LAYOUT_2_KHR };
	getDeviceImageSubresourceLayout(dev, &dsi, &dl);
	int ok = dl.subresourceLayout.rowPitch == PITCH;
	printf("%-4s vkGetDeviceImageSubresourceLayout rowPitch %llu (want %u)\n", ok ? "OK" : "FAIL",
	       (unsigned long long)dl.subresourceLayout.rowPitch, PITCH);
	fails += !ok;

	VkImage img;
	CK(vkCreateImage(dev, &ci, NULL, &img));
	VkImageSubresource sub = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0 };
	VkSubresourceLayout l;
	vkGetImageSubresourceLayout(dev, img, &sub, &l);
	ok = l.rowPitch == PITCH && l.offset == 0 && l.size >= (VkDeviceSize)PITCH * H;
	printf("%-4s vkGetImageSubresourceLayout offset %llu rowPitch %llu size %llu\n", ok ? "OK" : "FAIL",
	       (unsigned long long)l.offset, (unsigned long long)l.rowPitch, (unsigned long long)l.size);
	fails += !ok;
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(dev, img, &mr);
	ok = mr.size >= (VkDeviceSize)PITCH * H;
	printf("%-4s memory requirements size %llu (>= %u)\n", ok ? "OK" : "FAIL", (unsigned long long)mr.size, PITCH * H);
	fails += !ok;

	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = mem_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
	VkDeviceMemory mem;
	CK(vkAllocateMemory(dev, &mai, NULL, &mem));
	CK(vkBindImageMemory(dev, img, mem, 0));
	uint8_t *pix;
	CK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, (void **)&pix));
	for (uint32_t y = 0; y < H; y++)
		for (uint32_t x = 0; x < W; x++) {
			uint8_t *p = pix + (size_t)y * PITCH + x * 4;
			p[0] = (uint8_t)x; p[1] = (uint8_t)y; p[2] = (uint8_t)(x >> 8); p[3] = 0xff;
		}

	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = W * H * 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer rb;
	CK(vkCreateBuffer(dev, &bci, NULL, &rb));
	VkMemoryRequirements bmr;
	vkGetBufferMemoryRequirements(dev, rb, &bmr);
	VkMemoryAllocateInfo bmai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = bmr.size,
		.memoryTypeIndex = mem_type(bmr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
	VkDeviceMemory bmem;
	CK(vkAllocateMemory(dev, &bmai, NULL, &bmem));
	CK(vkBindBufferMemory(dev, rb, bmem, 0));
	uint8_t *out;
	CK(vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, (void **)&out));
	memset(out, 0, W * H * 4);

	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0 };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
		.commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
	VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	CK(vkBeginCommandBuffer(cmd, &bi));
	VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_HOST_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT, .oldLayout = VK_IMAGE_LAYOUT_PREINITIALIZED,
		.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
		.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = img,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b);
	VkBufferImageCopy region = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { W, H, 1 } };
	vkCmdCopyImageToBuffer(cmd, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rb, 1, &region);
	VkMemoryBarrier hb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &hb, 0, NULL, 0, NULL);
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(q));
	int bad = 0;
	for (uint32_t y = 0; y < H && !bad; y++)
		for (uint32_t x = 0; x < W && !bad; x++) {
			const uint8_t *p = out + ((size_t)y * W + x) * 4;
			bad = p[0] != (uint8_t)x || p[1] != (uint8_t)y || p[2] != (uint8_t)(x >> 8) || p[3] != 0xff;
			if (bad) printf("     first mismatch at (%u,%u): %02x %02x %02x %02x\n", x, y, p[0], p[1], p[2], p[3]);
		}
	printf("%-4s rows written at pitch %u read back by vkCmdCopyImageToBuffer\n", bad ? "FAIL" : "OK", PITCH);
	fails += bad;

	/* Too small a pitch must be rejected. */
	plane.rowPitch = 1024;
	VkImage img2 = VK_NULL_HANDLE;
	VkResult r = vkCreateImage(dev, &ci, NULL, &img2);
	ok = r == VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT;
	printf("%-4s rowPitch 1024 < 1200 rejected (VkResult %d)\n", ok ? "OK" : "FAIL", r);
	fails += !ok;
	if (img2) vkDestroyImage(dev, img2, NULL);

	vkDestroyImage(dev, img, NULL);
	vkFreeMemory(dev, mem, NULL);
	vkDestroyBuffer(dev, rb, NULL);
	vkFreeMemory(dev, bmem, NULL);
	vkDestroyCommandPool(dev, pool, NULL);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(inst, NULL);
	if (fails) {
		printf("linear_pitch: %d failure(s)\n", fails);
		return 1;
	}
	return 0;
}
