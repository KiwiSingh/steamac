/*
 * Host reproduction of gamescope 3.16.28's compute pipeline setup against libMoltenVK.
 *
 * Mirrors CVulkanDevice::createLayouts() and compilePipeline() (src/rendervulkan.cpp):
 * one descriptor set layout with
 *   0 uniform buffer, 1-2 storage images, 3 sampler2D[16], 4 sampler2D[16] with immutable
 *   YCbCr (NV12) samplers, 5 sampler1D[2], 6 sampler3D[2]
 * and one compute pipeline per shader + specialization variant.
 *
 *   gamescope_cs <dir with cs_*.spv>
 *
 * Exits non-zero if any pipeline fails to compile.
 */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define VKR_SAMPLER_SLOTS 16
#define VKR_LUT3D_COUNT 2

#define CK(x)                                                                          \
	do {                                                                               \
		VkResult r_ = (x);                                                             \
		if (r_ != VK_SUCCESS) {                                                        \
			fprintf(stderr, "%s failed: %d\n", #x, r_);                                \
			exit(2);                                                                   \
		}                                                                              \
	} while (0)

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

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s <dir with cs_*.spv>\n", argv[0]);
		return 2;
	}

	VkApplicationInfo app = {
		.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
		.pApplicationName = "gamescope-cs-repro",
		.apiVersion = VK_API_VERSION_1_3,
	};
	VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	CK(vkEnumeratePhysicalDevices(inst, &n, &pd));

	VkPhysicalDeviceVulkan11Features v11 = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		.samplerYcbcrConversion = VK_TRUE,
	};
	VkPhysicalDeviceFeatures2 f2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &v11 };
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
	};
	VkDevice dev;
	CK(vkCreateDevice(pd, &dci, NULL, &dev));

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
	VkSamplerCreateInfo sci = {
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
	CK(vkCreateSampler(dev, &sci, NULL, &ycbcr_sampler));
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
		for (size_t v = 0; v < sizeof(variants) / sizeof(variants[0]); v++) {
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
			else
				vkDestroyPipeline(dev, p, NULL);
		}
		vkDestroyShaderModule(dev, mod, NULL);
		free(code);
		free(names[s]);
	}
	printf("%d/%d pipelines compiled\n", total - fails, total);

	vkDestroyPipelineLayout(dev, layout, NULL);
	vkDestroyDescriptorSetLayout(dev, dsl, NULL);
	vkDestroySampler(dev, ycbcr_sampler, NULL);
	vkDestroySamplerYcbcrConversion(dev, conv, NULL);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(inst, NULL);
	return fails != 0;
}
