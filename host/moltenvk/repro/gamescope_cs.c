/*
 * Host reproduction of gamescope 3.16.28's compute pipelines against libMoltenVK.
 *
 * Mirrors CVulkanDevice::createLayouts() and compilePipeline() (src/rendervulkan.cpp):
 * one descriptor set layout with
 *   0 uniform buffer (layers_t), 1-2 storage images, 3 sampler2D[16],
 *   4 sampler2D[16] with immutable Y'CbCr (NV12) samplers, 5 sampler1D[2], 6 sampler3D[2]
 * and one compute pipeline per shader and specialization variant.
 *
 * Then it runs cs_composite_blit twice on an 8x8 target and checks the written pixels:
 *   - layer 0 from s_samplers[0]: an RGBA8 pattern (nearest, unnormalized sampler, as gamescope)
 *   - layer 0 from s_ycbcr_samplers[0]: a uniform NV12 image (Y=235, Cb=Cr=128 -> white)
 * The LUT bindings are null descriptors (gamescope's "no LUT" state, VK_EXT_robustness2).
 *
 *   gamescope_cs <dir with cs_*.spv> [robust2]
 *
 * robust2 also enables robustBufferAccess and VK_EXT_robustness2 robustBufferAccess2 (bounds-checked
 * buffer accesses in the MSL; DXVK enables them, and gamescope's composite shaders failed to compile with
 * them: the robust select of the packed mat3x4 u_ctm[] element).
 *
 * Exits non-zero if any pipeline fails to compile or a pixel is wrong.
 */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define VKR_SAMPLER_SLOTS 16
#define VKR_LUT3D_COUNT 2
#define VKR_MAX_LAYERS 6
#define W 8
#define H 8

#define CK(x)                                                                          \
	do {                                                                               \
		VkResult r_ = (x);                                                             \
		if (r_ != VK_SUCCESS) {                                                        \
			fprintf(stderr, "%s failed: %d (line %d)\n", #x, r_, __LINE__);            \
			exit(2);                                                                   \
		}                                                                              \
	} while (0)

static VkPhysicalDevice pd;
static VkDevice dev;
static VkQueue queue;
static VkCommandPool pool;

/* gamescope's layers_t (shaders/blit_push_data.h), scalar block layout */
struct layers {
	float scale[VKR_MAX_LAYERS][2];
	float offset[VKR_MAX_LAYERS][2];
	float opacity[VKR_MAX_LAYERS];
	float ctm[VKR_MAX_LAYERS][3][4];
	uint32_t border_mask, frame_id, blur_radius, shader_filter, alpha_mode;
	float linear_to_nits, nits_to_linear, itm_sdr_nits, itm_target_nits;
	uint32_t rotation;
};

static uint32_t *load(const char *path, size_t *size)
{
	FILE *f = fopen(path, "rb");
	if (!f) {
		perror(path);
		exit(2);
	}
	fseek(f, 0, SEEK_END);
	*size = (size_t)ftell(f);
	rewind(f);
	uint32_t *buf = malloc(*size);
	if (fread(buf, 1, *size, f) != *size) {
		perror(path);
		exit(2);
	}
	fclose(f);
	return buf;
}

static int cmp(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

static uint32_t mem_type(uint32_t bits, VkMemoryPropertyFlags flags)
{
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & flags) == flags)
			return i;
	fprintf(stderr, "no memory type for bits 0x%x flags 0x%x\n", bits, flags);
	exit(2);
}

static VkDeviceMemory alloc(VkMemoryRequirements mr, VkMemoryPropertyFlags flags)
{
	VkMemoryAllocateInfo ai = {
		.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		.allocationSize = mr.size,
		.memoryTypeIndex = mem_type(mr.memoryTypeBits, flags),
	};
	VkDeviceMemory m;
	CK(vkAllocateMemory(dev, &ai, NULL, &m));
	return m;
}

static VkBuffer host_buffer(VkDeviceSize size, VkBufferUsageFlags usage, void **map)
{
	VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage };
	VkBuffer b;
	CK(vkCreateBuffer(dev, &bci, NULL, &b));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, b, &mr);
	VkDeviceMemory m = alloc(mr, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	CK(vkBindBufferMemory(dev, b, m, 0));
	CK(vkMapMemory(dev, m, 0, VK_WHOLE_SIZE, 0, map));
	return b;
}

static VkImage device_image(VkFormat format, VkImageUsageFlags usage)
{
	VkImageCreateInfo ci = {
		.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
		.imageType = VK_IMAGE_TYPE_2D,
		.format = format,
		.extent = { W, H, 1 },
		.mipLevels = 1,
		.arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT,
		.tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = usage,
	};
	VkImage img;
	CK(vkCreateImage(dev, &ci, NULL, &img));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(dev, img, &mr);
	CK(vkBindImageMemory(dev, img, alloc(mr, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT), 0));
	return img;
}

static VkImageView view(VkImage img, VkFormat format, const void *next)
{
	VkImageViewCreateInfo ci = {
		.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
		.pNext = next,
		.image = img,
		.viewType = VK_IMAGE_VIEW_TYPE_2D,
		.format = format,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
	};
	VkImageView v;
	CK(vkCreateImageView(dev, &ci, NULL, &v));
	return v;
}

static VkCommandBuffer begin(void)
{
	VkCommandBufferAllocateInfo ai = {
		.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.commandPool = pool,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
		.commandBufferCount = 1,
	};
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &ai, &cmd));
	VkCommandBufferBeginInfo bi = {
		.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
	};
	CK(vkBeginCommandBuffer(cmd, &bi));
	return cmd;
}

static void submit(VkCommandBuffer cmd)
{
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));
	vkFreeCommandBuffers(dev, pool, 1, &cmd);
}

static void barrier(VkCommandBuffer cmd, VkImage img, VkImageAspectFlags aspect, VkImageLayout from, VkImageLayout to)
{
	VkImageMemoryBarrier b = {
		.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
		.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
		.oldLayout = from,
		.newLayout = to,
		.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
		.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
		.image = img,
		.subresourceRange = { aspect, 0, 1, 0, 1 },
	};
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0,
	                     NULL, 1, &b);
}

/* Test pattern for s_samplers[0]: 0/255 channels only, so gamma encode/decode are exact. */
static void pattern(int x, int y, uint8_t px[4])
{
	static const uint8_t colors[5][4] = {
		{ 255, 0, 0, 255 }, { 0, 255, 0, 255 }, { 0, 0, 255, 255 }, { 255, 255, 255, 255 }, { 0, 0, 0, 255 },
	};
	memcpy(px, colors[(x + 2 * y) % 5], 4);
}

int main(int argc, char **argv)
{
	if (argc != 2 && !(argc == 3 && !strcmp(argv[2], "robust2"))) {
		fprintf(stderr, "usage: %s <dir with cs_*.spv> [robust2]\n", argv[0]);
		return 2;
	}
	VkBool32 robust2 = argc == 3;
	if (robust2)
		printf("robustBufferAccess + robustBufferAccess2 enabled\n");

	VkApplicationInfo app = {
		.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
		.pApplicationName = "gamescope-cs-repro",
		.apiVersion = VK_API_VERSION_1_3,
	};
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	CK(vkEnumeratePhysicalDevices(inst, &n, &pd));

	VkPhysicalDeviceRobustness2FeaturesEXT rb2 = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
		.robustBufferAccess2 = robust2,
		.nullDescriptor = VK_TRUE,
	};
	VkPhysicalDeviceVulkan12Features v12 = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		.pNext = &rb2,
		.scalarBlockLayout = VK_TRUE,
	};
	VkPhysicalDeviceVulkan11Features v11 = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		.pNext = &v12,
		.samplerYcbcrConversion = VK_TRUE,
	};
	VkPhysicalDeviceFeatures2 f2 = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
		.pNext = &v11,
		.features = { .robustBufferAccess = robust2 },
	};
	const char *exts[] = { VK_EXT_ROBUSTNESS_2_EXTENSION_NAME };
	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = {
		.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
		.queueCount = 1,
		.pQueuePriorities = &prio,
	};
	VkDeviceCreateInfo dci = {
		.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.pNext = &f2,
		.queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci,
		.enabledExtensionCount = 1,
		.ppEnabledExtensionNames = exts,
	};
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	vkGetDeviceQueue(dev, 0, 0, &queue);
	VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	CK(vkCreateCommandPool(dev, &pci, NULL, &pool));

	/* CVulkanDevice::createLayouts() */
	VkFormatProperties nv12;
	vkGetPhysicalDeviceFormatProperties(pd, VK_FORMAT_G8_B8R8_2PLANE_420_UNORM, &nv12);
	int cosited = (nv12.optimalTilingFeatures & VK_FORMAT_FEATURE_COSITED_CHROMA_SAMPLES_BIT) != 0;
	VkSamplerYcbcrConversionCreateInfo yci = {
		.sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_CREATE_INFO,
		.format = VK_FORMAT_G8_B8R8_2PLANE_420_UNORM,
		.ycbcrModel = VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_709,
		.ycbcrRange = VK_SAMPLER_YCBCR_RANGE_ITU_NARROW,
		.xChromaOffset = cosited ? VK_CHROMA_LOCATION_COSITED_EVEN : VK_CHROMA_LOCATION_MIDPOINT,
		.yChromaOffset = cosited ? VK_CHROMA_LOCATION_COSITED_EVEN : VK_CHROMA_LOCATION_MIDPOINT,
		.chromaFilter = VK_FILTER_LINEAR,
	};
	VkSamplerYcbcrConversion conv;
	CK(vkCreateSamplerYcbcrConversion(dev, &yci, NULL, &conv));
	VkSamplerYcbcrConversionInfo yinfo = {
		.sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO,
		.conversion = conv,
	};
	VkSamplerCreateInfo ysci = {
		.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
		.pNext = &yinfo,
		.magFilter = VK_FILTER_LINEAR,
		.minFilter = VK_FILTER_LINEAR,
		.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
		.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
		.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
		.borderColor = VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK,
	};
	VkSampler ycbcr_sampler;
	CK(vkCreateSampler(dev, &ysci, NULL, &ycbcr_sampler));
	VkSampler ycbcr_samplers[VKR_SAMPLER_SLOTS];
	for (int i = 0; i < VKR_SAMPLER_SLOTS; i++)
		ycbcr_samplers[i] = ycbcr_sampler;

	const VkShaderStageFlags cs = VK_SHADER_STAGE_COMPUTE_BIT;
	VkDescriptorSetLayoutBinding b[7] = {
		{ 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, cs, NULL },
		{ 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, cs, NULL },
		{ 2, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, cs, NULL },
		{ 3, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, VKR_SAMPLER_SLOTS, cs, NULL },
		{ 4, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, VKR_SAMPLER_SLOTS, cs, ycbcr_samplers },
		{ 5, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, VKR_LUT3D_COUNT, cs, NULL },
		{ 6, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, VKR_LUT3D_COUNT, cs, NULL },
	};
	VkDescriptorSetLayoutCreateInfo dslci = {
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.bindingCount = 7,
		.pBindings = b,
	};
	VkDescriptorSetLayout dsl;
	CK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
	VkPipelineLayoutCreateInfo plci = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.setLayoutCount = 1,
		.pSetLayouts = &dsl,
	};
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));

	/* CVulkanDevice::compilePipeline(): spec constants 0..6, each a uint32 */
	VkSpecializationMapEntry entries[7];
	for (uint32_t i = 0; i < 7; i++)
		entries[i] = (VkSpecializationMapEntry){ i, i * 4, 4 };
	struct { uint32_t layer_count, ycbcr_mask, blur_layers; } variants[] = {
		{ 1, 0, 0 }, /* plain blit */
		{ 1, 1, 0 }, /* one NV12 layer */
		{ 2, 2, 1 }, /* two layers, second NV12, blur */
	};
	enum { NVARIANTS = sizeof(variants) / sizeof(variants[0]) };

	char *names[64];
	int count = 0;
	DIR *d = opendir(argv[1]);
	if (!d) {
		perror(argv[1]);
		return 2;
	}
	for (struct dirent *e; (e = readdir(d)) && count < 64;) {
		size_t l = strlen(e->d_name);
		if (l > 4 && !strcmp(e->d_name + l - 4, ".spv"))
			names[count++] = strdup(e->d_name);
	}
	closedir(d);
	qsort(names, (size_t)count, sizeof(names[0]), cmp);
	if (!count) {
		fprintf(stderr, "no .spv files in %s\n", argv[1]);
		return 2;
	}

	int fails = 0, total = 0;
	VkPipeline blit[NVARIANTS] = { 0 };
	for (int s = 0; s < count; s++) {
		char path[4096];
		snprintf(path, sizeof(path), "%s/%s", argv[1], names[s]);
		size_t size;
		uint32_t *code = load(path, &size);
		VkShaderModuleCreateInfo smci = {
			.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
			.codeSize = size,
			.pCode = code,
		};
		VkShaderModule mod;
		CK(vkCreateShaderModule(dev, &smci, NULL, &mod));
		int is_blit = !strcmp(names[s], "cs_composite_blit.spv");
		for (int v = 0; v < NVARIANTS; v++) {
			uint32_t data[7] = { variants[v].layer_count, variants[v].ycbcr_mask, 0,
			                     variants[v].blur_layers, 0, 0, 0 };
			VkSpecializationInfo si = { 7, entries, sizeof(data), data };
			VkComputePipelineCreateInfo cpci = {
				.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
				.stage = {
					.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
					.stage = VK_SHADER_STAGE_COMPUTE_BIT,
					.module = mod,
					.pName = "main",
					.pSpecializationInfo = &si,
				},
				.layout = layout,
			};
			VkPipeline p = VK_NULL_HANDLE;
			VkResult r = vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &p);
			total++;
			printf("%-4s %s layers=%u ycbcrMask=%u blur=%u (VkResult %d)\n", r == VK_SUCCESS ? "OK" : "FAIL",
			       names[s], variants[v].layer_count, variants[v].ycbcr_mask, variants[v].blur_layers, r);
			if (r != VK_SUCCESS)
				fails++;
			else if (is_blit)
				blit[v] = p;
			else
				vkDestroyPipeline(dev, p, NULL);
		}
		vkDestroyShaderModule(dev, mod, NULL);
		free(code);
		free(names[s]);
	}
	printf("%d/%d pipelines compiled\n", total - fails, total);
	if (!blit[0] || !blit[1]) {
		printf("cs_composite_blit pipelines missing, skipping the render test\n");
		return 1;
	}

	/* --- resources for the render test */
	VkImage dst = device_image(VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
	VkImageView dst_view = view(dst, VK_FORMAT_R8G8B8A8_UNORM, NULL);
	VkImage rgba = device_image(VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT);
	VkImageView rgba_view = view(rgba, VK_FORMAT_R8G8B8A8_UNORM, NULL);
	VkImage yuv = device_image(VK_FORMAT_G8_B8R8_2PLANE_420_UNORM,
	                           VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT);
	VkImageView yuv_view = view(yuv, VK_FORMAT_G8_B8R8_2PLANE_420_UNORM, &yinfo);

	/* gamescope's sampler for s_samplers: nearest + unnormalized coordinates */
	VkSamplerCreateInfo sci = {
		.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
		.magFilter = VK_FILTER_NEAREST,
		.minFilter = VK_FILTER_NEAREST,
		.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
		.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
		.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
		.borderColor = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
		.unnormalizedCoordinates = VK_TRUE,
	};
	VkSampler nearest;
	CK(vkCreateSampler(dev, &sci, NULL, &nearest));

	/* upload: RGBA pattern, then NV12 plane 0 (Y=235) and plane 1 (Cb=Cr=128) */
	uint8_t *staging;
	VkBuffer staging_buf = host_buffer(4096, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, (void **)&staging);
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++)
			pattern(x, y, staging + (y * W + x) * 4);
	memset(staging + 1024, 235, W * H);
	memset(staging + 2048, 128, (W / 2) * (H / 2) * 2);
	VkCommandBuffer cmd = begin();
	barrier(cmd, rgba, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
	barrier(cmd, yuv, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
	VkBufferImageCopy copies[3] = {
		{ .bufferOffset = 0, .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { W, H, 1 } },
		{ .bufferOffset = 1024, .imageSubresource = { VK_IMAGE_ASPECT_PLANE_0_BIT, 0, 0, 1 }, .imageExtent = { W, H, 1 } },
		{ .bufferOffset = 2048, .imageSubresource = { VK_IMAGE_ASPECT_PLANE_1_BIT, 0, 0, 1 },
		  .imageExtent = { W / 2, H / 2, 1 } },
	};
	vkCmdCopyBufferToImage(cmd, staging_buf, rgba, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copies[0]);
	vkCmdCopyBufferToImage(cmd, staging_buf, yuv, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 2, &copies[1]);
	barrier(cmd, rgba, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
	        VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
	barrier(cmd, yuv, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
	        VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
	barrier(cmd, dst, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL);
	submit(cmd);

	struct layers *ubo;
	VkBuffer ubo_buf = host_buffer(sizeof(*ubo), VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, (void **)&ubo);
	memset(ubo, 0, sizeof(*ubo));
	for (int i = 0; i < VKR_MAX_LAYERS; i++) {
		ubo->scale[i][0] = ubo->scale[i][1] = 1.0f;
		ubo->offset[i][0] = ubo->offset[i][1] = 0.5f; /* offsetPixelCenter() */
		ubo->opacity[i] = 1.0f;
		ubo->ctm[i][0][0] = ubo->ctm[i][1][1] = ubo->ctm[i][2][2] = 1.0f;
	}
	ubo->shader_filter = 1; /* filter_nearest for layer 0 */
	ubo->linear_to_nits = 400.0f;
	ubo->nits_to_linear = 1.0f / 400.0f;
	uint8_t *readback;
	VkBuffer readback_buf = host_buffer(W * H * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, (void **)&readback);

	VkDescriptorPoolSize sizes[] = {
		{ VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1 },
		{ VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 2 },
		{ VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2 * VKR_SAMPLER_SLOTS + 2 * VKR_LUT3D_COUNT },
	};
	VkDescriptorPoolCreateInfo dpci = {
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
		.maxSets = 1,
		.poolSizeCount = 3,
		.pPoolSizes = sizes,
	};
	VkDescriptorPool dpool;
	CK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));
	VkDescriptorSetAllocateInfo dsai = {
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
		.descriptorPool = dpool,
		.descriptorSetCount = 1,
		.pSetLayouts = &dsl,
	};
	VkDescriptorSet set;
	CK(vkAllocateDescriptorSets(dev, &dsai, &set));

	/* As gamescope: every slot written; unused ones and the LUTs are null descriptors. */
	VkDescriptorBufferInfo ubo_info = { ubo_buf, 0, sizeof(*ubo) };
	VkDescriptorImageInfo dst_info[2] = { { VK_NULL_HANDLE, dst_view, VK_IMAGE_LAYOUT_GENERAL },
	                                      { VK_NULL_HANDLE, VK_NULL_HANDLE, VK_IMAGE_LAYOUT_GENERAL } };
	VkDescriptorImageInfo samplers[VKR_SAMPLER_SLOTS], ycbcr[VKR_SAMPLER_SLOTS], luts[VKR_LUT3D_COUNT];
	for (int i = 0; i < VKR_SAMPLER_SLOTS; i++) {
		samplers[i] = (VkDescriptorImageInfo){ nearest, i == 0 ? rgba_view : VK_NULL_HANDLE,
		                                       VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
		ycbcr[i] = (VkDescriptorImageInfo){ VK_NULL_HANDLE, i == 0 ? yuv_view : VK_NULL_HANDLE,
		                                    VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
	}
	for (int i = 0; i < VKR_LUT3D_COUNT; i++)
		luts[i] = (VkDescriptorImageInfo){ nearest, VK_NULL_HANDLE, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
	VkWriteDescriptorSet writes[7] = {
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, 0, 0, 1, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, NULL, &ubo_info, NULL },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, 1, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, &dst_info[0], NULL, NULL },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, 2, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, &dst_info[1], NULL, NULL },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, 3, 0, VKR_SAMPLER_SLOTS, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, samplers, NULL, NULL },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, 4, 0, VKR_SAMPLER_SLOTS, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, ycbcr, NULL, NULL },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, 5, 0, VKR_LUT3D_COUNT, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, luts, NULL, NULL },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, set, 6, 0, VKR_LUT3D_COUNT, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, luts, NULL, NULL },
	};
	vkUpdateDescriptorSets(dev, 7, writes, 0, NULL);

	/* --- render test: variant 0 samples s_samplers[0], variant 1 samples s_ycbcr_samplers[0] */
	for (int v = 0; v < 2; v++) {
		cmd = begin();
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, blit[v]);
		vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
		vkCmdDispatch(cmd, (W + 7) / 8, (H + 7) / 8, 1);
		barrier(cmd, dst, VK_IMAGE_ASPECT_COLOR_BIT, VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_GENERAL);
		VkBufferImageCopy rc = {
			.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
			.imageExtent = { W, H, 1 },
		};
		vkCmdCopyImageToBuffer(cmd, dst, VK_IMAGE_LAYOUT_GENERAL, readback_buf, 1, &rc);
		submit(cmd);

		int bad = 0;
		for (int y = 0; y < H; y++)
			for (int x = 0; x < W; x++) {
				uint8_t want[4] = { 255, 255, 255, 255 };
				if (v == 0)
					pattern(x, y, want);
				const uint8_t *got = readback + (y * W + x) * 4;
				for (int c = 0; c < 4; c++)
					if (abs((int)got[c] - (int)want[c]) > 3) {
						if (bad++ < 4)
							printf("  pixel (%d,%d): got %3u %3u %3u %3u want %3u %3u %3u %3u\n", x, y, got[0],
							       got[1], got[2], got[3], want[0], want[1], want[2], want[3]);
						break;
					}
			}
		printf("%-4s render cs_composite_blit layer 0 from %s: %d/%d pixels correct\n", bad ? "FAIL" : "OK",
		       v == 0 ? "s_samplers[0] (RGBA pattern)" : "s_ycbcr_samplers[0] (NV12 white)", W * H - bad, W * H);
		if (bad)
			fails++;
	}

	vkDeviceWaitIdle(dev);
	return fails != 0;
}
