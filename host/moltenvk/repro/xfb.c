/*
 * Transform feedback (VK_EXT_transform_feedback) captured by geometry shaders.
 *
 * DXVK's D3D11 stream output uses geometry shaders that output points with only captured varyings
 * (no position) and rasterizer discard; zink puts a geometry shader on every draw, so GL transform
 * feedback goes through it too. Every case reads the transform feedback buffers back and compares
 * every captured value with the values the Vulkan spec requires (primitive order, strip
 * decomposition, buffer offsets, sizes, counters). shaders/:
 *   so.vert             triangle list, vertex v at position (v, 0, 0, 1)
 *   so_points.geom      3 points per input triangle, no position, 4 outputs, stride 40 (DXVK-style),
 *                       pipeline with rasterizer discard and no fragment shader
 *   so_strip.geom       triangle strip of 3 or 4 vertices per input primitive (1 or 2 triangles:
 *                       varying vertex count per primitive, odd strip triangle order), captures
 *                       gl_Position (gl_PerVertex member) + a varying in buffer 0 and a uint in
 *                       buffer 1, rasterizing
 *   so_lines.geom       line strip of 3 vertices (2 lines) per input primitive
 *   so_vs.vert          vertex shader capturing (no geometry shader): pipeline creation must fail
 *                       with VK_ERROR_FEATURE_NOT_PRESENT
 * Counter buffers: a second Begin resumes at the counter written by End; a bound range too small
 * for all primitives records only the primitives that fit, and the counter stops there.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static const char *dir;
static VkDevice dev;
static VkPhysicalDevice pd;
static VkQueue queue;
static VkCommandPool pool;
static VkPipelineLayout layout;
static PFN_vkCmdBindTransformFeedbackBuffersEXT bind_xfb;
static PFN_vkCmdBeginTransformFeedbackEXT begin_xfb;
static PFN_vkCmdEndTransformFeedbackEXT end_xfb;
enum { W = 16, H = 16 };

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

static uint32_t mem_type(uint32_t bits, VkMemoryPropertyFlags want)
{
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
			return i;
	return 0;
}

/* Host-visible buffer of the given usage, mapped. */
static VkBuffer buffer(VkDeviceSize size, VkBufferUsageFlags usage, void **map)
{
	VkBufferCreateInfo ci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage };
	VkBuffer b;
	CK(vkCreateBuffer(dev, &ci, NULL, &b));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, b, &mr);
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = mem_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
	VkDeviceMemory m;
	CK(vkAllocateMemory(dev, &ai, NULL, &m));
	CK(vkBindBufferMemory(dev, b, m, 0));
	CK(vkMapMemory(dev, m, 0, VK_WHOLE_SIZE, 0, map));
	return b;
}

static VkResult pipeline(const char *vs, const char *gs, int fragment, int discard, VkPrimitiveTopology topology,
                         VkPipeline *out)
{
	VkPipelineShaderStageCreateInfo st[3];
	uint32_t n = 0;
	st[n++] = (VkPipelineShaderStageCreateInfo){ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
		.stage = VK_SHADER_STAGE_VERTEX_BIT, .module = module(vs), .pName = "main" };
	if (gs)
		st[n++] = (VkPipelineShaderStageCreateInfo){ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			.stage = VK_SHADER_STAGE_GEOMETRY_BIT, .module = module(gs), .pName = "main" };
	if (fragment)
		st[n++] = (VkPipelineShaderStageCreateInfo){ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
			.stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = module("f.frag.spv"), .pName = "main" };
	VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = topology };
	VkViewport vp = { 0, 0, W, H, 0, 1 };
	VkRect2D sc = { { 0, 0 }, { W, H } };
	VkPipelineViewportStateCreateInfo vps = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		.viewportCount = 1, .pViewports = &vp, .scissorCount = 1, .pScissors = &sc };
	VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.rasterizerDiscardEnable = discard, .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE,
		.lineWidth = 1 };
	VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		.attachmentCount = 1, .pAttachments = &cba };
	VkFormat cf = VK_FORMAT_R8G8B8A8_UNORM;
	VkPipelineRenderingCreateInfo ri = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
		.colorAttachmentCount = 1, .pColorAttachmentFormats = &cf };
	VkGraphicsPipelineCreateInfo ci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = &ri,
		.stageCount = n, .pStages = st, .pVertexInputState = &vi, .pInputAssemblyState = &ia,
		.pViewportState = &vps, .pRasterizationState = &rs, .pMultisampleState = &ms,
		.pColorBlendState = &cb, .layout = layout };
	*out = VK_NULL_HANDLE;
	return vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &ci, NULL, out);
}

static VkImageView target;

static VkCommandBuffer begin_cmd(void)
{
	VkCommandBufferAllocateInfo ai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
		.commandBufferCount = 1 };
	VkCommandBuffer cmd;
	CK(vkAllocateCommandBuffers(dev, &ai, &cmd));
	VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	CK(vkBeginCommandBuffer(cmd, &bi));
	VkRenderingAttachmentInfo att = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = target,
		.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
		.storeOp = VK_ATTACHMENT_STORE_OP_STORE };
	VkRenderingInfo rinfo = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { W, H } },
		.layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &att };
	vkCmdBeginRendering(cmd, &rinfo);
	return cmd;
}

static void end_cmd(VkCommandBuffer cmd)
{
	vkCmdEndRendering(cmd);
	VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFORM_FEEDBACK_WRITE_BIT_EXT |
		VK_ACCESS_TRANSFORM_FEEDBACK_COUNTER_WRITE_BIT_EXT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFORM_FEEDBACK_BIT_EXT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0,
	                     NULL, 0, NULL);
	CK(vkEndCommandBuffer(cmd));
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));
	vkFreeCommandBuffers(dev, pool, 1, &cmd);
}

static int fails;

static void check(int ok, const char *what)
{
	printf("%-4s %s\n", ok ? "OK" : "FAIL", what);
	fails += !ok;
}

static int feq(float a, float b) { return a == b; }

/* so_points: captured vertex k (in order) of input primitive p, point i. */
static int points_vertex_ok(const uint8_t *rec, uint32_t p, uint32_t i)
{
	const float *a = (const float *)rec, *b = (const float *)(rec + 16), *c = (const float *)(rec + 32);
	uint32_t d = *(const uint32_t *)(rec + 36);
	return feq(a[0], (float)(3 * p + i)) && feq(a[1], 0) && feq(a[2], 0) && feq(a[3], 1) && feq(b[0], (float)p) &&
	       feq(b[1], (float)i) && feq(b[2], 1) && feq(b[3], 2) && feq(c[0], 0.5f + (float)i) && d == 10 * p + i;
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s <spv dir>\n", argv[0]);
		return 2;
	}
	dir = argv[1];

	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	VkPhysicalDeviceTransformFeedbackFeaturesEXT xfbf = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT,
		.transformFeedback = VK_TRUE };
	VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, &xfbf,
		.dynamicRendering = VK_TRUE };
	VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v13,
		.features = { .geometryShader = VK_TRUE } };
	const char *exts[] = { VK_EXT_TRANSFORM_FEEDBACK_EXTENSION_NAME };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f2, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci, .enabledExtensionCount = 1, .ppEnabledExtensionNames = exts };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	vkGetDeviceQueue(dev, 0, 0, &queue);
	bind_xfb = (PFN_vkCmdBindTransformFeedbackBuffersEXT)vkGetDeviceProcAddr(dev, "vkCmdBindTransformFeedbackBuffersEXT");
	begin_xfb = (PFN_vkCmdBeginTransformFeedbackEXT)vkGetDeviceProcAddr(dev, "vkCmdBeginTransformFeedbackEXT");
	end_xfb = (PFN_vkCmdEndTransformFeedbackEXT)vkGetDeviceProcAddr(dev, "vkCmdEndTransformFeedbackEXT");
	VkCommandPoolCreateInfo pci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	CK(vkCreateCommandPool(dev, &pci, NULL, &pool));
	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));

	VkPhysicalDeviceTransformFeedbackPropertiesEXT xfbp = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_PROPERTIES_EXT };
	VkPhysicalDeviceProperties2 p2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &xfbp };
	vkGetPhysicalDeviceProperties2(pd, &p2);
	char msg[256];
	snprintf(msg, sizeof(msg), "properties: %u buffers, %u streams, buffer size %llu, stride %u, queries %u, draw %u",
	         xfbp.maxTransformFeedbackBuffers, xfbp.maxTransformFeedbackStreams,
	         (unsigned long long)xfbp.maxTransformFeedbackBufferSize, xfbp.maxTransformFeedbackBufferDataStride,
	         xfbp.transformFeedbackQueries, xfbp.transformFeedbackDraw);
	check(xfbp.maxTransformFeedbackBuffers >= 2 && xfbp.maxTransformFeedbackStreams == 1 &&
	      xfbp.maxTransformFeedbackBufferDataStride >= 40, msg);

	/* Render target (only for the rasterizing case). */
	VkImageCreateInfo imci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
		.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT };
	VkImage img;
	CK(vkCreateImage(dev, &imci, NULL, &img));
	VkMemoryRequirements imr;
	vkGetImageMemoryRequirements(dev, img, &imr);
	VkMemoryAllocateInfo iai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = imr.size,
		.memoryTypeIndex = mem_type(imr.memoryTypeBits, 0) };
	VkDeviceMemory imem;
	CK(vkAllocateMemory(dev, &iai, NULL, &imem));
	CK(vkBindImageMemory(dev, img, imem, 0));
	VkImageViewCreateInfo ivci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img,
		.viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	CK(vkCreateImageView(dev, &ivci, NULL, &target));

	const VkBufferUsageFlags xfb_usage = VK_BUFFER_USAGE_TRANSFORM_FEEDBACK_BUFFER_BIT_EXT;
	const VkBufferUsageFlags counter_usage = VK_BUFFER_USAGE_TRANSFORM_FEEDBACK_COUNTER_BUFFER_BIT_EXT;

	/* 1. DXVK-style points without position, rasterizer discard, no fragment shader. Buffer 0 bound
	 *    at offset 64; two draws of 2 triangles each, the second in a new Begin that resumes at the
	 *    counter written by the first End. Expect 12 records: primitives 0, 1 of each draw. */
	{
		VkPipeline p;
		VkResult r = pipeline("so.vert.spv", "so_points.geom.spv", 0, 1, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, &p);
		snprintf(msg, sizeof(msg), "create so.vert + so_points.geom (no position, rasterizer discard) (VkResult %d)", r);
		check(r == VK_SUCCESS, msg);
		if (r == VK_SUCCESS) {
			uint8_t *xb, *cb;
			VkBuffer xbuf = buffer(1024, xfb_usage, (void **)&xb);
			VkBuffer cbuf = buffer(16, counter_usage, (void **)&cb);
			memset(xb, 0xcd, 1024);
			memset(cb, 0, 16);
			VkDeviceSize off = 64, size = 1024 - 64, coff = 4;
			VkCommandBuffer cmd = begin_cmd();
			vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p);
			bind_xfb(cmd, 0, 1, &xbuf, &off, &size);
			begin_xfb(cmd, 0, 0, NULL, NULL);
			vkCmdDraw(cmd, 6, 1, 0, 0);
			end_xfb(cmd, 0, 1, &cbuf, &coff);
			begin_xfb(cmd, 0, 1, &cbuf, &coff);
			vkCmdDraw(cmd, 6, 1, 0, 0);
			end_xfb(cmd, 0, 1, &cbuf, &coff);
			end_cmd(cmd);
			int ok = 1;
			for (uint32_t k = 0; k < 12; k++)
				ok &= points_vertex_ok(xb + 64 + 40 * k, (k / 3) % 2, k % 3);
			for (uint32_t k = 0; k < 64; k++)
				ok &= xb[k] == 0xcd;		/* before the bound offset: untouched */
			ok &= xb[64 + 480] == 0xcd;	/* after the last record: untouched */
			uint32_t counter = *(uint32_t *)(cb + 4);
			snprintf(msg, sizeof(msg), "so_points: 2 x 2 triangles -> 12 records at offset 64, counter resumed (counter %u, want 480)",
			         counter);
			check(ok && counter == 480, msg);
		}
	}

	/* 2. Bound range too small: 4 records of 40 bytes fit, 3 per primitive -> only primitive 0
	 *    (3 records) is written, the counter stops at 120, primitive 1 is not recorded. */
	{
		VkPipeline p;
		if (pipeline("so.vert.spv", "so_points.geom.spv", 0, 1, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, &p) == VK_SUCCESS) {
			uint8_t *xb, *cb;
			VkBuffer xbuf = buffer(1024, xfb_usage, (void **)&xb);
			VkBuffer cbuf = buffer(16, counter_usage, (void **)&cb);
			memset(xb, 0xcd, 1024);
			memset(cb, 0, 16);
			VkDeviceSize off = 0, size = 160, coff = 0;
			VkCommandBuffer cmd = begin_cmd();
			vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p);
			bind_xfb(cmd, 0, 1, &xbuf, &off, &size);
			begin_xfb(cmd, 0, 0, NULL, NULL);
			vkCmdDraw(cmd, 6, 1, 0, 0);
			end_xfb(cmd, 0, 1, &cbuf, &coff);
			end_cmd(cmd);
			int ok = 1;
			for (uint32_t k = 0; k < 3; k++)
				ok &= points_vertex_ok(xb + 40 * k, 0, k);
			ok &= xb[120] == 0xcd;
			uint32_t counter = *(uint32_t *)cb;
			snprintf(msg, sizeof(msg), "so_points: range for 4 records -> primitive 0 only (counter %u, want 120)", counter);
			check(ok && counter == 120, msg);
		}
	}

	/* 3. Triangle strips with 3 or 4 vertices per input primitive (4 input triangles), two buffers,
	 *    rasterizing. Primitive p emits vertices 0..n-1, n = 3 + p % 2: triangles (0, 1, 2) and, for
	 *    odd p, (1, 3, 2). Expect 3 + 6 + 3 + 6 = 18 records in primitive order. */
	{
		VkPipeline p;
		VkResult r = pipeline("so.vert.spv", "so_strip.geom.spv", 1, 0, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, &p);
		snprintf(msg, sizeof(msg), "create so.vert + so_strip.geom + f.frag (VkResult %d)", r);
		check(r == VK_SUCCESS, msg);
		if (r == VK_SUCCESS) {
			uint8_t *xb0, *xb1;
			VkBuffer bufs[2] = { buffer(1024, xfb_usage, (void **)&xb0), buffer(1024, xfb_usage, (void **)&xb1) };
			memset(xb0, 0xcd, 1024);
			memset(xb1, 0xcd, 1024);
			VkDeviceSize offs[2] = { 0, 0 };
			VkCommandBuffer cmd = begin_cmd();
			vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p);
			bind_xfb(cmd, 0, 2, bufs, offs, NULL);
			begin_xfb(cmd, 0, 0, NULL, NULL);
			vkCmdDraw(cmd, 12, 1, 0, 0);
			end_xfb(cmd, 0, 0, NULL, NULL);
			end_cmd(cmd);
			int ok = 1;
			uint32_t k = 0;
			for (uint32_t prim = 0; prim < 4; prim++) {
				static const uint32_t even[3] = { 0, 1, 2 }, odd[6] = { 0, 1, 2, 1, 3, 2 };
				const uint32_t *order = prim % 2 ? odd : even;
				for (uint32_t j = 0; j < (prim % 2 ? 6u : 3u); j++, k++) {
					uint32_t i = order[j];
					const float *pos = (const float *)(xb0 + 32 * k), *col = (const float *)(xb0 + 32 * k + 16);
					ok &= feq(pos[0], (float)(3 * prim + i % 3)) && feq(pos[3], 1.0f + (float)i);
					ok &= feq(col[0], (float)prim) && feq(col[1], (float)i);
					ok &= *(const uint32_t *)(xb1 + 8 * k + 4) == 100 * prim + i;
					ok &= *(const uint32_t *)(xb1 + 8 * k) == 0xcdcdcdcd;	/* not captured: unmodified */
				}
			}
			ok &= xb0[32 * 18] == 0xcd && xb1[8 * 18 + 4] == 0xcd;
			check(ok, "so_strip: 1 or 2 strip triangles per input primitive, 2 buffers -> 18 records in order");
		}
	}

	/* 4. Line strip of 3 vertices per input primitive: lines (0, 1), (1, 2) -> 4 records each. */
	{
		VkPipeline p;
		VkResult r = pipeline("so.vert.spv", "so_lines.geom.spv", 1, 0, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, &p);
		snprintf(msg, sizeof(msg), "create so.vert + so_lines.geom + f.frag (VkResult %d)", r);
		check(r == VK_SUCCESS, msg);
		if (r == VK_SUCCESS) {
			uint8_t *xb;
			VkBuffer xbuf = buffer(1024, xfb_usage, (void **)&xb);
			memset(xb, 0xcd, 1024);
			VkDeviceSize off = 0;
			VkCommandBuffer cmd = begin_cmd();
			vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p);
			bind_xfb(cmd, 0, 1, &xbuf, &off, NULL);
			begin_xfb(cmd, 0, 0, NULL, NULL);
			vkCmdDraw(cmd, 6, 1, 0, 0);
			end_xfb(cmd, 0, 0, NULL, NULL);
			end_cmd(cmd);
			int ok = 1;
			static const uint32_t order[4] = { 0, 1, 1, 2 };
			for (uint32_t k = 0; k < 8; k++) {
				const float *a = (const float *)(xb + 16 * k);
				ok &= feq(a[0], (float)(k / 4)) && feq(a[1], (float)order[k % 4]);
			}
			ok &= xb[16 * 8] == 0xcd;
			check(ok, "so_lines: line strips decomposed into lines -> 8 records in order");
		}
	}

	/* 5. Transform feedback inactive: nothing is written. */
	{
		VkPipeline p;
		if (pipeline("so.vert.spv", "so_points.geom.spv", 0, 1, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, &p) == VK_SUCCESS) {
			uint8_t *xb;
			VkBuffer xbuf = buffer(1024, xfb_usage, (void **)&xb);
			memset(xb, 0xcd, 1024);
			VkDeviceSize off = 0;
			VkCommandBuffer cmd = begin_cmd();
			vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, p);
			bind_xfb(cmd, 0, 1, &xbuf, &off, NULL);
			vkCmdDraw(cmd, 6, 1, 0, 0);
			end_cmd(cmd);
			int ok = 1;
			for (uint32_t k = 0; k < 1024; k++)
				ok &= xb[k] == 0xcd;
			check(ok, "so_points without vkCmdBeginTransformFeedbackEXT: nothing written");
		}
	}

	/* 6. Vertex shader capturing without a geometry shader: clean pipeline creation failure. */
	{
		VkPipeline p;
		VkResult r = pipeline("so_vs.vert.spv", NULL, 1, 0, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, &p);
		snprintf(msg, sizeof(msg), "so_vs.vert (vertex shader transform feedback) fails cleanly (VkResult %d, want %d)", r,
		         VK_ERROR_FEATURE_NOT_PRESENT);
		check(r == VK_ERROR_FEATURE_NOT_PRESENT || r == VK_ERROR_INITIALIZATION_FAILED, msg);
	}

	if (fails) {
		printf("xfb: %d failure(s)\n", fails);
		return 1;
	}
	return 0;
}
