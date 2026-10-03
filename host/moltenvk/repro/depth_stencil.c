/*
 * Depth/stencil images the way zink allocates GL renderbuffers.
 *
 * zink creates depth/stencil renderbuffers with TRANSFER_SRC|TRANSFER_DST|SAMPLED|
 * DEPTH_STENCIL_ATTACHMENT, plus HOST_TRANSFER when the format reports
 * VK_FORMAT_FEATURE_2_HOST_IMAGE_TRANSFER_BIT and vkGetPhysicalDeviceImageFormatProperties2
 * accepts it. MoltenVK used to accept HOST_TRANSFER for depth/stencil formats, but such
 * images need private memory and HOST_TRANSFER excludes private memory, so memoryTypeBits
 * was 0, zink could not allocate any depth/stencil renderbuffer, and every GL framebuffer
 * with a depth or stencil attachment was incomplete (Steam's CEF/Skia: "failed to attach a
 * stencil buffer").
 *
 * For S8_UINT, D16_UNORM, D32_SFLOAT and D32_SFLOAT_S8_UINT (plus D24_UNORM_S8_UINT and
 * X8_D24_UNORM_PACK32 when supported) this checks, for the usages above with and without
 * HOST_TRANSFER:
 *   - the format has DEPTH_STENCIL_ATTACHMENT in optimalTilingFeatures,
 *   - every usage the driver accepts gives an image with memoryTypeBits != 0 that can be
 *     allocated and bound,
 *   - the zink renderbuffer usage (without HOST_TRANSFER) is accepted,
 *   - a cleared image reads back the clear value (vkCmdClearDepthStencilImage +
 *     vkCmdCopyImageToBuffer of each aspect).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static VkPhysicalDevice pd;
static VkDevice dev;
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
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);

	uint32_t en = 0;
	vkEnumerateDeviceExtensionProperties(pd, NULL, &en, NULL);
	VkExtensionProperties *ext = calloc(en, sizeof(*ext));
	vkEnumerateDeviceExtensionProperties(pd, NULL, &en, ext);
	int has_hic = 0, has_portability = 0;
	for (uint32_t i = 0; i < en; i++) {
		has_hic |= !strcmp(ext[i].extensionName, VK_EXT_HOST_IMAGE_COPY_EXTENSION_NAME);
		has_portability |= !strcmp(ext[i].extensionName, "VK_KHR_portability_subset");
	}
	free(ext);
	VkPhysicalDeviceHostImageCopyFeaturesEXT hicf = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_HOST_IMAGE_COPY_FEATURES_EXT };
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, has_hic ? &hicf : NULL };
	vkGetPhysicalDeviceFeatures2(pd, &f2);
	const char *dext[2];
	uint32_t dext_n = 0;
	if (has_hic && hicf.hostImageCopy) dext[dext_n++] = VK_EXT_HOST_IMAGE_COPY_EXTENSION_NAME;
	if (has_portability) dext[dext_n++] = "VK_KHR_portability_subset";
	VkPhysicalDeviceHostImageCopyFeaturesEXT hic_on = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_HOST_IMAGE_COPY_FEATURES_EXT,
		.hostImageCopy = VK_TRUE };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1,
		.pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, (has_hic && hicf.hostImageCopy) ? &hic_on : NULL,
		.queueCreateInfoCount = 1, .pQueueCreateInfos = &qci, .enabledExtensionCount = dext_n, .ppEnabledExtensionNames = dext };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue q;
	vkGetDeviceQueue(dev, 0, 0, &q);
	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0,
		.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
		.commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));

	/* Readback buffer (host visible). */
	const uint32_t W = 64, H = 64;
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = W * H * 8,
		.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer rb;
	CK(vkCreateBuffer(dev, &bci, NULL, &rb));
	VkMemoryRequirements bmr;
	vkGetBufferMemoryRequirements(dev, rb, &bmr);
	VkMemoryAllocateInfo bmai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = bmr.size,
		.memoryTypeIndex = mem_type(bmr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
	VkDeviceMemory bmem;
	CK(vkAllocateMemory(dev, &bmai, NULL, &bmem));
	CK(vkBindBufferMemory(dev, rb, bmem, 0));
	void *map;
	CK(vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, &map));

	struct { VkFormat f; const char *name; int required; } fmts[] = {
		{ VK_FORMAT_S8_UINT, "S8_UINT", 1 },
		{ VK_FORMAT_D16_UNORM, "D16_UNORM", 1 },
		{ VK_FORMAT_D32_SFLOAT, "D32_SFLOAT", 1 },
		{ VK_FORMAT_D32_SFLOAT_S8_UINT, "D32_SFLOAT_S8_UINT", 1 },
		{ VK_FORMAT_D24_UNORM_S8_UINT, "D24_UNORM_S8_UINT", 0 },
		{ VK_FORMAT_X8_D24_UNORM_PACK32, "X8_D24_UNORM_PACK32", 0 },
	};
	const VkImageUsageFlags zink_usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT |
		VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
	int fails = 0;
	for (size_t i = 0; i < sizeof(fmts) / sizeof(fmts[0]); i++) {
		VkFormat f = fmts[i].f;
		VkFormatProperties3 p3 = { VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_3 };
		VkFormatProperties2 p2 = { VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2, &p3 };
		vkGetPhysicalDeviceFormatProperties2(pd, f, &p2);
		if (!(p3.optimalTilingFeatures & VK_FORMAT_FEATURE_2_DEPTH_STENCIL_ATTACHMENT_BIT)) {
			printf("%-4s %s: no DEPTH_STENCIL_ATTACHMENT (optimal 0x%llx)\n", fmts[i].required ? "FAIL" : "skip",
			       fmts[i].name, (unsigned long long)p3.optimalTilingFeatures);
			fails += fmts[i].required;
			continue;
		}
		int has_depth = f != VK_FORMAT_S8_UINT;
		int has_stencil = f == VK_FORMAT_S8_UINT || f == VK_FORMAT_D32_SFLOAT_S8_UINT || f == VK_FORMAT_D24_UNORM_S8_UINT;
		for (int ht = 0; ht < 2; ht++) {
			VkImageUsageFlags usage = zink_usage | (ht ? VK_IMAGE_USAGE_HOST_TRANSFER_BIT_EXT : 0);
			VkPhysicalDeviceImageFormatInfo2 ii = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2, .format = f,
				.type = VK_IMAGE_TYPE_2D, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = usage };
			VkImageFormatProperties2 ip = { VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2 };
			VkResult r = vkGetPhysicalDeviceImageFormatProperties2(pd, &ii, &ip);
			if (r != VK_SUCCESS) {
				int ok = ht;   /* HOST_TRANSFER may be rejected; the plain zink usage must not be */
				printf("%-4s %s usage 0x%x%s: not supported (%d)\n", ok ? "OK" : "FAIL", fmts[i].name, usage,
				       ht ? " (HOST_TRANSFER)" : "", r);
				fails += !ok;
				continue;
			}
			if (ht && !(has_hic && hicf.hostImageCopy)) {
				printf("skip %s usage 0x%x: HOST_TRANSFER accepted but hostImageCopy unavailable\n", fmts[i].name, usage);
				continue;
			}
			VkImageCreateInfo ci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = f,
				.extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
				.tiling = VK_IMAGE_TILING_OPTIMAL, .usage = usage, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
			VkImage img;
			CK(vkCreateImage(dev, &ci, NULL, &img));
			VkMemoryRequirements mr;
			vkGetImageMemoryRequirements(dev, img, &mr);
			uint32_t t = mem_type(mr.memoryTypeBits, 0);
			if (t == UINT32_MAX) {
				printf("FAIL %s usage 0x%x%s: supported, but memoryTypeBits = 0x%x\n", fmts[i].name, usage,
				       ht ? " (HOST_TRANSFER)" : "", mr.memoryTypeBits);
				fails++;
				vkDestroyImage(dev, img, NULL);
				continue;
			}
			VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
				.memoryTypeIndex = t };
			VkDeviceMemory mem;
			CK(vkAllocateMemory(dev, &mai, NULL, &mem));
			CK(vkBindImageMemory(dev, img, mem, 0));

			/* Clear, then read every aspect back. */
			VkImageAspectFlags aspects = (has_depth ? VK_IMAGE_ASPECT_DEPTH_BIT : 0) |
				(has_stencil ? VK_IMAGE_ASPECT_STENCIL_BIT : 0);
			VkImageSubresourceRange range = { aspects, 0, 1, 0, 1 };
			CK(vkResetCommandBuffer(cmd, 0));
			VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
				.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
			CK(vkBeginCommandBuffer(cmd, &bi));
			VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
				.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
				.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
				.image = img, .subresourceRange = range };
			vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL,
			                     1, &b);
			VkClearDepthStencilValue cv = { 0.5f, 0x5a };
			vkCmdClearDepthStencilImage(cmd, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &cv, 1, &range);
			b.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
			b.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
			b.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
			b.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
			vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL,
			                     1, &b);
			VkBufferImageCopy regions[2];
			uint32_t nreg = 0;
			VkDeviceSize stencil_off = W * H * 4;
			if (has_depth)
				regions[nreg++] = (VkBufferImageCopy){ .bufferOffset = 0,
					.imageSubresource = { VK_IMAGE_ASPECT_DEPTH_BIT, 0, 0, 1 }, .imageExtent = { W, H, 1 } };
			if (has_stencil)
				regions[nreg++] = (VkBufferImageCopy){ .bufferOffset = stencil_off,
					.imageSubresource = { VK_IMAGE_ASPECT_STENCIL_BIT, 0, 0, 1 }, .imageExtent = { W, H, 1 } };
			memset(map, 0, W * H * 8);
			vkCmdCopyImageToBuffer(cmd, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rb, nreg, regions);
			VkMemoryBarrier hb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
				.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
			vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &hb, 0, NULL, 0, NULL);
			CK(vkEndCommandBuffer(cmd));
			VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
			CK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE));
			CK(vkQueueWaitIdle(q));

			int bad = 0;
			const uint8_t *px = map;
			for (uint32_t k = 0; k < W * H && !bad; k++) {
				if (has_depth) {
					double d;
					if (f == VK_FORMAT_D16_UNORM) d = ((const uint16_t *)px)[k] / 65535.0;
					else if (f == VK_FORMAT_D24_UNORM_S8_UINT || f == VK_FORMAT_X8_D24_UNORM_PACK32)
						d = (((const uint32_t *)px)[k] & 0xffffff) / 16777215.0;
					else d = ((const float *)px)[k];
					bad |= d < 0.49 || d > 0.51;
				}
				if (has_stencil) bad |= px[stencil_off + k] != 0x5a;
			}
			printf("%-4s %s usage 0x%x%s: memoryTypeBits 0x%x, clear/readback %s\n", bad ? "FAIL" : "OK", fmts[i].name,
			       usage, ht ? " (HOST_TRANSFER)" : "", mr.memoryTypeBits, bad ? "wrong" : "correct");
			fails += bad;
			vkDestroyImage(dev, img, NULL);
			vkFreeMemory(dev, mem, NULL);
		}
	}
	vkDestroyBuffer(dev, rb, NULL);
	vkFreeMemory(dev, bmem, NULL);
	vkDestroyCommandPool(dev, pool, NULL);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(inst, NULL);
	if (fails) {
		printf("depth_stencil: %d failure(s)\n", fails);
		return 1;
	}
	return 0;
}
