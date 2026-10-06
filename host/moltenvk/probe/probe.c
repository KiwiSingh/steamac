/*
 * Host Vulkan driver feature probe for steamac (MoltenVK, KosmicKrisp).
 *
 * Linked against libMoltenVK.dylib directly (no Vulkan loader), the way virglrenderer used
 * it, or against the Khronos loader with VK_DRIVER_FILES naming KosmicKrisp (which exports
 * only the loader-ICD interface). Prints the API version and the features/extensions DXVK,
 * vkd3d-proton and Zink care about, then exits non-zero if one of the features steamac
 * depends on is missing.
 *
 *   probe            print and check
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

static int has_ext(const VkExtensionProperties *e, uint32_t n, const char *name)
{
	for (uint32_t i = 0; i < n; i++)
		if (!strcmp(e[i].extensionName, name))
			return 1;
	return 0;
}

int main(void)
{
	VkApplicationInfo app = {
		.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
		.pApplicationName = "steamac-mvk-probe",
		.apiVersion = VK_API_VERSION_1_4,
	};
	VkInstanceCreateInfo ici = {
		.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
		.pApplicationInfo = &app,
	};
	VkInstance inst;
	if (vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS) {
		fprintf(stderr, "vkCreateInstance failed\n");
		return 1;
	}
	uint32_t n = 1;
	VkPhysicalDevice pd;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || n == 0) {
		fprintf(stderr, "no Vulkan physical device\n");
		return 1;
	}

	uint32_t en = 0;
	vkEnumerateDeviceExtensionProperties(pd, NULL, &en, NULL);
	VkExtensionProperties *ext = calloc(en, sizeof(*ext));
	vkEnumerateDeviceExtensionProperties(pd, NULL, &en, ext);

	VkPhysicalDeviceDepthClipEnableFeaturesEXT dce = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT,
	};
	VkPhysicalDeviceTransformFeedbackFeaturesEXT xfb = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT,
		.pNext = &dce,
	};
	VkPhysicalDeviceRobustness2FeaturesEXT rb2 = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
		.pNext = &xfb,
	};
	VkPhysicalDeviceMaintenance6FeaturesKHR m6 = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_6_FEATURES_KHR,
		.pNext = &rb2,
	};
	VkPhysicalDeviceMaintenance5FeaturesKHR m5 = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_5_FEATURES_KHR,
		.pNext = &m6,
	};
	VkPhysicalDeviceVulkan13Features v13 = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		.pNext = &m5,
	};
	VkPhysicalDeviceVulkan12Features v12 = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		.pNext = &v13,
	};
	VkPhysicalDeviceVulkan11Features v11 = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		.pNext = &v12,
	};
	VkPhysicalDeviceFeatures2 f2 = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
		.pNext = &v11,
	};
	vkGetPhysicalDeviceFeatures2(pd, &f2);
	const VkPhysicalDeviceFeatures *f = &f2.features;

	VkPhysicalDeviceTransformFeedbackPropertiesEXT xfbp = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_PROPERTIES_EXT,
	};
	VkPhysicalDeviceDriverProperties drv = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
		.pNext = &xfbp,
	};
	VkPhysicalDeviceProperties2 p2 = {
		.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
		.pNext = &drv,
	};
	vkGetPhysicalDeviceProperties2(pd, &p2);
	const VkPhysicalDeviceProperties *p = &p2.properties;

	printf("device:      %s\n", p->deviceName);
	printf("driver:      %s %s\n", drv.driverName, drv.driverInfo);
	printf("apiVersion:  %u.%u.%u\n", VK_API_VERSION_MAJOR(p->apiVersion),
	       VK_API_VERSION_MINOR(p->apiVersion), VK_API_VERSION_PATCH(p->apiVersion));

	int ext_dce = has_ext(ext, en, VK_EXT_DEPTH_CLIP_ENABLE_EXTENSION_NAME);
	int ext_xfb = has_ext(ext, en, VK_EXT_TRANSFORM_FEEDBACK_EXTENSION_NAME);
	int ext_rb2 = has_ext(ext, en, VK_EXT_ROBUSTNESS_2_EXTENSION_NAME);
	int ext_m5 = has_ext(ext, en, VK_KHR_MAINTENANCE_5_EXTENSION_NAME);
	int ext_m6 = has_ext(ext, en, VK_KHR_MAINTENANCE_6_EXTENSION_NAME);
	int ext_lson = has_ext(ext, en, VK_KHR_LOAD_STORE_OP_NONE_EXTENSION_NAME);

	/* Linear-tiled color formats must be renderable: zink/glamor render into linear dma-buf
	 * (scanout) images, and virglrenderer passes the host's linear tiling features through. */
	const VkFormatFeatureFlags linear_render = VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT |
		VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT | VK_FORMAT_FEATURE_BLIT_DST_BIT;
	const VkFormat scanout_formats[] = { VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_R8G8B8A8_UNORM,
		VK_FORMAT_A2R10G10B10_UNORM_PACK32, VK_FORMAT_A2B10G10R10_UNORM_PACK32 };
	int linear_renderable = 1;
	for (size_t i = 0; i < sizeof(scanout_formats) / sizeof(scanout_formats[0]); i++) {
		VkFormatProperties fp;
		vkGetPhysicalDeviceFormatProperties(pd, scanout_formats[i], &fp);
		printf("(info) format %d linearTilingFeatures 0x%08x\n", scanout_formats[i], fp.linearTilingFeatures);
		if ((fp.linearTilingFeatures & linear_render) != linear_render)
			linear_renderable = 0;
	}

	/* Depth/stencil formats zink uses for GL renderbuffers: S8_UINT (GL_STENCIL_INDEX8) and
	 * D32_SFLOAT_S8_UINT (GL_DEPTH24_STENCIL8, D24S8 is not supported on Apple GPUs) must be
	 * depth/stencil attachments. On MoltenVK they must not report HOST_IMAGE_TRANSFER: its
	 * depth/stencil images live in private memory, so a HOST_TRANSFER image would have no memory
	 * type (zink allocates renderbuffers with HOST_TRANSFER whenever the format reports it).
	 * KosmicKrisp gives them a memory type (repro/depth_stencil.c). */
	const VkFormat zs_formats[] = { VK_FORMAT_S8_UINT, VK_FORMAT_D16_UNORM, VK_FORMAT_D32_SFLOAT,
		VK_FORMAT_D32_SFLOAT_S8_UINT };
	int s8_attachment = 0, d32s8_attachment = 0, zs_no_host_transfer = 1;
	for (size_t i = 0; i < sizeof(zs_formats) / sizeof(zs_formats[0]); i++) {
		VkFormatProperties3 fp3 = { .sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_3 };
		VkFormatProperties2 fp2 = { .sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2, .pNext = &fp3 };
		vkGetPhysicalDeviceFormatProperties2(pd, zs_formats[i], &fp2);
		printf("(info) format %d optimalTilingFeatures 0x%llx\n", zs_formats[i],
		       (unsigned long long)fp3.optimalTilingFeatures);
		int att = (fp3.optimalTilingFeatures & VK_FORMAT_FEATURE_2_DEPTH_STENCIL_ATTACHMENT_BIT) != 0;
		if (zs_formats[i] == VK_FORMAT_S8_UINT)
			s8_attachment = att;
		if (zs_formats[i] == VK_FORMAT_D32_SFLOAT_S8_UINT)
			d32s8_attachment = att;
		if (fp3.optimalTilingFeatures & VK_FORMAT_FEATURE_2_HOST_IMAGE_TRANSFER_BIT)
			zs_no_host_transfer = 0;
	}

	struct { const char *name; int value; int required; } rows[] = {
		{ "geometryShader",                 f->geometryShader, 1 },
		{ "shaderCullDistance",             f->shaderCullDistance, 1 },
		{ "robustBufferAccess2",            ext_rb2 && rb2.robustBufferAccess2, 1 },
		{ "nullDescriptor",                 ext_rb2 && rb2.nullDescriptor, 1 },
		{ "depthClipEnable",                ext_dce && dce.depthClipEnable, 1 },
		{ "transformFeedback",              ext_xfb && xfb.transformFeedback, 0 },
		{ "maintenance5",                   ext_m5 && m5.maintenance5, 1 },
		{ "maintenance6",                   ext_m6 && m6.maintenance6, 1 },
		{ "linearColorAttachment",          linear_renderable, 1 },
		{ "S8_UINT DS attachment",          s8_attachment, 1 },
		{ "D32_SFLOAT_S8_UINT DS attachment", d32s8_attachment, 1 },
		{ "depth/stencil no host transfer", zs_no_host_transfer, drv.driverID == VK_DRIVER_ID_MOLTENVK },
		{ "KHR_load_store_op_none",         ext_lson, 0 },
		{ "scalarBlockLayout",              v12.scalarBlockLayout, 0 },
		{ "subgroupSizeControl",            v13.subgroupSizeControl, 0 },
		{ "computeFullSubgroups",           v13.computeFullSubgroups, 0 },
		{ "fillModeNonSolid",               f->fillModeNonSolid, 0 },
		{ "multiViewport",                  f->multiViewport, 0 },
		{ "dualSrcBlend",                   f->dualSrcBlend, 0 },
		{ "shaderInt64",                    f->shaderInt64, 0 },
		{ "textureCompressionBC",           f->textureCompressionBC, 0 },
		{ "samplerAnisotropy",              f->samplerAnisotropy, 0 },
		{ "inlineUniformBlock",             v13.inlineUniformBlock, 0 },
		{ "storageBuffer8BitAccess",        v12.storageBuffer8BitAccess, 0 },
		{ "storageBuffer16BitAccess",       v11.storageBuffer16BitAccess, 0 },
		{ "shaderInt8",                     v12.shaderInt8, 0 },
		{ "shaderInt16",                    f->shaderInt16, 0 },
		{ "logicOp",                        f->logicOp, 0 },
	};
	int missing = 0;
	for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
		printf("%-26s %d%s\n", rows[i].name, rows[i].value != 0,
		       rows[i].required && !rows[i].value ? "   <-- REQUIRED, MISSING" : "");
		if (rows[i].required && !rows[i].value)
			missing++;
	}
	printf("(info) robustImageAccess2=%d geometryStreams=%d transformFeedbackQueries=%d depthClamp=%d"
	       " wideLines=%d depthBounds=%d\n",
	       rb2.robustImageAccess2, xfb.geometryStreams, xfbp.transformFeedbackQueries, f->depthClamp,
	       f->wideLines, f->depthBounds);

	free(ext);
	vkDestroyInstance(inst, NULL);
	if (missing) {
		fprintf(stderr, "probe: %d required feature(s) missing\n", missing);
		return 1;
	}
	return 0;
}
