/*
 * robustBufferAccess2 (VK_EXT_robustness2, enabled by DXVK and vkd3d-proton) and texel buffer atomics:
 * MSL that SPIRV-Cross generated for these failed to compile on users' Macs, and some bounds were wrong.
 *
 *   rba_atomic_store.comp   imageAtomicStore() on a storage texel buffer ('atomic_store(3u, 0u).x')
 *   rba_struct_load.comp    struct loaded from a runtime array ('MatStorage(0)' as the out-of-bounds value,
 *                           bound computed with a 4-byte stride instead of the 64-byte ArrayStride)
 *   rba_packed_matrix.comp  packed mat3x4 array element in a scalar uniform block, column- and row-major
 *                           ('packed_float3x4' selected against 'float3x4(0)', gamescope's u_ctm[])
 *   rba_rmw.spvasm          read-modify-write through one access chain (the out-of-bounds store went to the
 *                           clamped last element) and a runtime array after a header (bound by
 *                           (size - offset) / stride)
 *   rba_array_load.comp     whole array loaded from a buffer
 *
 * Buffers are bound with ranges smaller than the buffers, filled with non-zero data: in-bounds reads must
 * return the data, out-of-bounds reads zero, out-of-bounds writes must be discarded.
 *
 *   robust_access <spv dir>
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
static VkPipelineLayout layout;
static VkDescriptorSet set;
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

static VkBuffer buffer(VkDeviceSize size, VkBufferUsageFlags usage, void **map)
{
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage };
	VkBuffer buf;
	CK(vkCreateBuffer(dev, &bci, NULL, &buf));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, buf, &mr);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	const VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
	uint32_t t = 0;
	while (!(mr.memoryTypeBits & (1u << t)) || (mp.memoryTypes[t].propertyFlags & want) != want)
		t++;
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = t };
	VkDeviceMemory mem;
	CK(vkAllocateMemory(dev, &mai, NULL, &mem));
	CK(vkBindBufferMemory(dev, buf, mem, 0));
	CK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, map));
	return buf;
}

static VkPipeline pipeline(const char *spv)
{
	VkComputePipelineCreateInfo ci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
		           .module = module(spv), .pName = "main" }, .layout = layout };
	VkPipeline p = VK_NULL_HANDLE;
	VkResult r = vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, &p);
	printf("%-4s create %s (VkResult %d)\n", r == VK_SUCCESS ? "OK" : "FAIL", spv, r);
	if (r) { fails++; return VK_NULL_HANDLE; }
	return p;
}

static void dispatch(VkPipeline p, uint32_t idx, uint32_t val)
{
	VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &cai, &cmd));
	VkCommandBufferBeginInfo cbbi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
	CK(vkBeginCommandBuffer(cmd, &cbbi));
	vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, p);
	vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
	uint32_t pc[2] = { idx, val };
	vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(pc), pc);
	vkCmdDispatch(cmd, 1, 1, 1);
	VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));
	vkFreeCommandBuffers(dev, pool, 1, &cmd);
}

static void check_vec4(const char *what, const float *got, const float *want)
{
	int ok = !memcmp(got, want, 4 * sizeof(float));
	printf("%-4s %s: (%g %g %g %g), expected (%g %g %g %g)\n", ok ? "OK" : "FAIL", what,
	       got[0], got[1], got[2], got[3], want[0], want[1], want[2], want[3]);
	fails += !ok;
}

static VkDeviceSize align_up(VkDeviceSize v, VkDeviceSize a)
{
	return a > 1 ? (v + a - 1) / a * a : v;
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

	VkPhysicalDeviceRobustness2PropertiesEXT rb2props = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_PROPERTIES_EXT };
	VkPhysicalDeviceProperties2 props = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &rb2props };
	vkGetPhysicalDeviceProperties2(pd, &props);
	VkFormatProperties fp;
	vkGetPhysicalDeviceFormatProperties(pd, VK_FORMAT_R32_UINT, &fp);
	if (!(fp.bufferFeatures & VK_FORMAT_FEATURE_STORAGE_TEXEL_BUFFER_ATOMIC_BIT)) {
		printf("FAIL R32_UINT storage texel buffer atomics not supported\n");
		return 1;
	}

	VkPhysicalDeviceRobustness2FeaturesEXT rb2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
		.robustBufferAccess2 = VK_TRUE };
	VkPhysicalDeviceVulkan12Features v12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &rb2,
		.scalarBlockLayout = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v12,
		.features = { .robustBufferAccess = VK_TRUE } };
	const char *exts[] = { VK_EXT_ROBUSTNESS_2_EXTENSION_NAME };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
		.enabledExtensionCount = 1, .ppEnabledExtensionNames = exts };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	vkGetDeviceQueue(dev, 0, 0, &queue);
	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));

	const VkShaderStageFlags cs = VK_SHADER_STAGE_COMPUTE_BIT;
	VkDescriptorSetLayoutBinding b[6] = {
		{ 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, cs, NULL },       /* In (limited range) */
		{ 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, cs, NULL },       /* Out */
		{ 2, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, cs, NULL },       /* U: column-major mat3x4[4] (limited range) */
		{ 3, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 1, cs, NULL }, /* u0: r32ui */
		{ 4, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, cs, NULL },       /* Rmw (limited range) */
		{ 5, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, cs, NULL },       /* R: row-major mat3x4[4] (limited range) */
	};
	VkDescriptorSetLayoutCreateInfo dslci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 6, .pBindings = b };
	VkDescriptorSetLayout dsl;
	CK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
	VkPushConstantRange pcr = { cs, 0, 8 };
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl,
		.pushConstantRangeCount = 1, .pPushConstantRanges = &pcr };
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));

	/* Data: float k + 1 at float index k. */
	float *in, *ubo, *out;
	uint32_t *texels, *rmw;
	VkBuffer inb = buffer(4096, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, (void **)&in);
	VkBuffer outb = buffer(256, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, (void **)&out);
	VkBuffer ubob = buffer(4096, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, (void **)&ubo);
	VkBuffer texb = buffer(256, VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT, (void **)&texels);
	VkBuffer rmwb = buffer(256, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, (void **)&rmw);
	for (int k = 0; k < 1024; k++)
		in[k] = ubo[k] = (float)(k + 1);
	memset(texels, 0, 256);
	memset(rmw, 0, 256);

	const VkDeviceSize in_range = 256, ubo_range = 8 + 2 * 48, rmw_range = 64;
	/* Ranges as the device may round them (robust*BufferAccessSizeAlignment). */
	VkDeviceSize in_eff = align_up(in_range, rb2props.robustStorageBufferAccessSizeAlignment);
	VkDeviceSize ubo_eff = align_up(ubo_range, rb2props.robustUniformBufferAccessSizeAlignment);
	VkDeviceSize rmw_eff = align_up(rmw_range, rb2props.robustStorageBufferAccessSizeAlignment);
	printf("     ranges: In %llu, U/R %llu, Rmw %llu bytes (robust size alignment storage %llu, uniform %llu)\n",
	       (unsigned long long)in_range, (unsigned long long)ubo_range, (unsigned long long)rmw_range,
	       (unsigned long long)rb2props.robustStorageBufferAccessSizeAlignment,
	       (unsigned long long)rb2props.robustUniformBufferAccessSizeAlignment);

	VkBufferViewCreateInfo bvci = { VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO, .buffer = texb, .format = VK_FORMAT_R32_UINT, .range = VK_WHOLE_SIZE };
	VkBufferView texview;
	CK(vkCreateBufferView(dev, &bvci, NULL, &texview));

	VkDescriptorPoolSize ps[3] = { { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 3 }, { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2 },
		{ VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 1 } };
	VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 3, .pPoolSizes = ps };
	VkDescriptorPool dpool;
	CK(vkCreateDescriptorPool(dev, &dpci, NULL, &dpool));
	VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dpool, .descriptorSetCount = 1, .pSetLayouts = &dsl };
	CK(vkAllocateDescriptorSets(dev, &dsai, &set));
	VkDescriptorBufferInfo dbi[5] = { { inb, 0, in_range }, { outb, 0, VK_WHOLE_SIZE }, { ubob, 0, ubo_range },
		{ rmwb, 0, rmw_range }, { ubob, 0, ubo_range } };
	VkWriteDescriptorSet w[6] = {
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 0, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi[0] },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 1, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi[1] },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 2, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = &dbi[2] },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 3, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, .pTexelBufferView = &texview },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 4, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi[3] },
		{ VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .dstBinding = 5, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = &dbi[4] },
	};
	vkUpdateDescriptorSets(dev, 6, w, 0, NULL);

	char what[128];

	/* --- texel buffer atomic store: texel 3 = val, texel idx = val + 1 */
	VkPipeline p = pipeline("rba_atomic_store.comp.spv");
	if (p) {
		dispatch(p, 10, 7);
		int ok = texels[3] == 7 && texels[10] == 8;
		for (int k = 0; k < 64; k++)
			ok &= k == 3 || k == 10 || texels[k] == 0;
		printf("%-4s rba_atomic_store: texel[3] = %u (expected 7), texel[10] = %u (expected 8), others 0\n",
		       ok ? "OK" : "FAIL", texels[3], texels[10]);
		fails += !ok;
	}

	/* --- struct (vec4 data[4], 64 bytes) from a runtime array; In holds in_eff / 64 elements */
	p = pipeline("rba_struct_load.comp.spv");
	if (p) {
		uint32_t idxs[] = { 2, 4, 100000 };
		for (size_t t = 0; t < sizeof(idxs) / sizeof(idxs[0]); t++) {
			memset(out, 0xff, 256);
			dispatch(p, idxs[t], 0);
			int inside = (idxs[t] + 1) * 64 <= in_eff;
			for (int j = 0; j < 4; j++) {
				float want[4];
				for (int c = 0; c < 4; c++)
					want[c] = inside ? in[idxs[t] * 16 + j * 4 + c] : 0.0f;
				snprintf(what, sizeof(what), "rba_struct_load bones[%u].data[%d]%s", idxs[t], j, inside ? "" : " (out of bounds)");
				check_vec4(what, out + 4 * j, want);
			}
		}
	}

	/* --- packed mat3x4 ctm[4] after a vec2 (offset 8, 48-byte stride), column- and row-major:
	 * o[0].xyz = vec4(1, 2, 3, 4) * ctm[idx], o[1].xyz = vec4(1, 2, 3, 4) * rm[idx] */
	p = pipeline("rba_packed_matrix.comp.spv");
	if (p) {
		for (uint32_t idx = 0; idx < 4; idx++) {
			memset(out, 0xff, 256);
			dispatch(p, idx, 0);
			int inside = 8 + (idx + 1) * 48 <= ubo_eff;
			float cm[4] = { 0 }, rm[4] = { 0 };
			for (int j = 0; j < 3 && inside; j++)
				for (int r = 0; r < 4; r++) {
					cm[j] += (r + 1) * ubo[2 + 12 * idx + 4 * j + r];
					rm[j] += (r + 1) * ubo[2 + 12 * idx + 3 * r + j];
				}
			snprintf(what, sizeof(what), "rba_packed_matrix column-major ctm[%u]%s", idx, inside ? "" : " (out of bounds)");
			check_vec4(what, out, cm);
			snprintf(what, sizeof(what), "rba_packed_matrix row-major rm[%u]%s", idx, inside ? "" : " (out of bounds)");
			check_vec4(what, out + 4, rm);
		}
	}

	/* --- r[idx] += 1 (Rmw holds rmw_eff / 4 uints), o[0].x = inb.f[idx] (f[] at offset 4) */
	p = pipeline("rba_rmw.spv");
	if (p) {
		uint32_t idxs[] = { 5, 16, 62, 63 };
		uint32_t expect_rmw[64] = { 0 };
		for (size_t t = 0; t < sizeof(idxs) / sizeof(idxs[0]); t++) {
			memset(out, 0xff, 256);
			dispatch(p, idxs[t], 0);
			if ((idxs[t] + 1) * 4 <= rmw_eff)
				expect_rmw[idxs[t]]++;
			int inside = 4 + (idxs[t] + 1) * 4 <= in_eff;
			float want[4] = { inside ? in[1 + idxs[t]] : 0.0f, 0, 0, 0 };
			snprintf(what, sizeof(what), "rba_rmw inb.f[%u]%s", idxs[t], inside ? "" : " (out of bounds)");
			check_vec4(what, out, want);
		}
		int ok = !memcmp(rmw, expect_rmw, sizeof(expect_rmw));
		printf("%-4s rba_rmw r[] += 1 at 5, 16, 62, 63: r[5] = %u, r[15] = %u, r[16] = %u (in bounds: %llu uints)\n",
		       ok ? "OK" : "FAIL", rmw[5], rmw[15], rmw[16], (unsigned long long)(rmw_eff / 4));
		fails += !ok;
	}

	/* --- float a[4] = s[idx].a (16-byte elements) */
	p = pipeline("rba_array_load.comp.spv");
	if (p) {
		uint32_t idxs[] = { 3, 16 };
		for (size_t t = 0; t < sizeof(idxs) / sizeof(idxs[0]); t++) {
			memset(out, 0xff, 256);
			dispatch(p, idxs[t], 0);
			int inside = (idxs[t] + 1) * 16 <= in_eff;
			float want[4];
			for (int c = 0; c < 4; c++)
				want[c] = inside ? in[idxs[t] * 4 + c] : 0.0f;
			snprintf(what, sizeof(what), "rba_array_load s[%u].a%s", idxs[t], inside ? "" : " (out of bounds)");
			check_vec4(what, out, want);
		}
	}

	if (fails) { printf("robust_access: %d failure(s)\n", fails); return 1; }
	return 0;
}
