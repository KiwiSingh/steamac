/*
 * Occlusion query results copied with vkCmdCopyQueryPoolResults from a later command buffer, the way Venus
 * reads every query (query feedback: one copy per ended query, 64-bit with availability and
 * VK_QUERY_RESULT_WAIT_BIT). The copy of a query other than 0 read the availability of query 0 onward and
 * skipped the "are the queries ended" check, so DXVK's occlusion queries never became available in the guest.
 *
 * v.vert + f.frag (left-half triangle) into a 16x16 target; occlusion pool of 8 queries, all reset:
 *   query 5: the triangle             -> available, samples > 0
 *   query 2: no draws                 -> available, 0 samples
 *   queries 3 and 4: never begun      -> unavailable, results untouched
 * Copies: 5 and 2 each (64-bit, availability, wait), 3..4 (64-bit, availability), 5 (32-bit, availability);
 * vkGetQueryPoolResults of query 5 must match.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

enum { W = 16, H = 16 };

static VkDevice dev;
static VkPhysicalDevice pd;

static VkShaderModule module(const char *dir, const char *name)
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
	for (uint32_t t = 0; t < mp.memoryTypeCount; t++)
		if ((bits & (1u << t)) && (mp.memoryTypes[t].propertyFlags & want) == want)
			return t;
	printf("FAIL no memory type\n");
	exit(1);
}

int main(int argc, char **argv)
{
	if (argc != 2) { fprintf(stderr, "usage: %s <spv dir>\n", argv[0]); return 2; }
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	VkPhysicalDeviceVulkan13Features v13 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, .dynamicRendering = VK_TRUE };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &v13, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue queue;
	vkGetDeviceQueue(dev, 0, 0, &queue);

	VkImageCreateInfo imci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1,
		.samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT };
	VkImage img;
	CK(vkCreateImage(dev, &imci, NULL, &img));
	VkMemoryRequirements mr;
	vkGetImageMemoryRequirements(dev, img, &mr);
	VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = mem_type(mr.memoryTypeBits, 0) };
	VkDeviceMemory imem;
	CK(vkAllocateMemory(dev, &mai, NULL, &imem));
	CK(vkBindImageMemory(dev, img, imem, 0));
	VkImageViewCreateInfo ivci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img, .viewType = VK_IMAGE_VIEW_TYPE_2D,
		.format = VK_FORMAT_R8G8B8A8_UNORM, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	VkImageView view;
	CK(vkCreateImageView(dev, &ivci, NULL, &view));

	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 256, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
	VkBuffer buf;
	CK(vkCreateBuffer(dev, &bci, NULL, &buf));
	vkGetBufferMemoryRequirements(dev, buf, &mr);
	mai.allocationSize = mr.size;
	mai.memoryTypeIndex = mem_type(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
	VkDeviceMemory bmem;
	CK(vkAllocateMemory(dev, &mai, NULL, &bmem));
	CK(vkBindBufferMemory(dev, buf, bmem, 0));
	uint8_t *map;
	CK(vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, (void **)&map));
	memset(map, 0xab, 256);

	VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO };
	VkPipelineLayout layout;
	CK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
	VkPipelineShaderStageCreateInfo stages[2] = {
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
		  .module = module(argv[1], "v.vert.spv"), .pName = "main" },
		{ VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
		  .module = module(argv[1], "f.frag.spv"), .pName = "main" },
	};
	VkPipelineVertexInputStateCreateInfo vi = { VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
	VkPipelineInputAssemblyStateCreateInfo ia = { VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
	VkViewport vp = { 0, 0, W, H, 0, 1 };
	VkRect2D sc = { { 0, 0 }, { W, H } };
	VkPipelineViewportStateCreateInfo vps = { VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1,
		.pViewports = &vp, .scissorCount = 1, .pScissors = &sc };
	VkPipelineRasterizationStateCreateInfo rs = { VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		.polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1 };
	VkPipelineMultisampleStateCreateInfo ms = { VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
	VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
	VkPipelineColorBlendStateCreateInfo cb = { VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1,
		.pAttachments = &cba };
	VkFormat fmt = VK_FORMAT_R8G8B8A8_UNORM;
	VkPipelineRenderingCreateInfo prci = { VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .colorAttachmentCount = 1,
		.pColorAttachmentFormats = &fmt };
	VkGraphicsPipelineCreateInfo gpci = { VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, &prci, .stageCount = 2,
		.pStages = stages, .pVertexInputState = &vi, .pInputAssemblyState = &ia, .pViewportState = &vps,
		.pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cb, .layout = layout };
	VkPipeline pipe;
	CK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpci, NULL, &pipe));

	VkQueryPoolCreateInfo qpci = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_OCCLUSION, .queryCount = 8 };
	VkQueryPool qp;
	CK(vkCreateQueryPool(dev, &qpci, NULL, &qp));
	VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
	VkCommandPool pool;
	CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
	VkCommandBufferAllocateInfo ai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 2 };
	VkCommandBuffer cmds[2];
	CK(vkAllocateCommandBuffers(dev, &ai, cmds));
	VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1 };

	/* The application's command buffer. */
	CK(vkBeginCommandBuffer(cmds[0], &bi));
	vkCmdResetQueryPool(cmds[0], qp, 0, 8);
	VkImageMemoryBarrier ib = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
		.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = img,
		.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
	vkCmdPipelineBarrier(cmds[0], VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL,
	                     0, NULL, 1, &ib);
	VkRenderingAttachmentInfo att = { VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = view,
		.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
		.storeOp = VK_ATTACHMENT_STORE_OP_STORE };
	VkRenderingInfo rinfo = { VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = sc, .layerCount = 1,
		.colorAttachmentCount = 1, .pColorAttachments = &att };
	vkCmdBeginRendering(cmds[0], &rinfo);
	vkCmdBindPipeline(cmds[0], VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
	vkCmdBeginQuery(cmds[0], qp, 5, 0);
	vkCmdDraw(cmds[0], 3, 1, 0, 0);
	vkCmdEndQuery(cmds[0], qp, 5);
	vkCmdBeginQuery(cmds[0], qp, 2, 0);
	vkCmdEndQuery(cmds[0], qp, 2);
	vkCmdEndRendering(cmds[0]);
	CK(vkEndCommandBuffer(cmds[0]));
	si.pCommandBuffers = &cmds[0];
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));

	/* Venus' query feedback, submitted after it. */
	const VkQueryResultFlags fb = VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT;
	CK(vkBeginCommandBuffer(cmds[1], &bi));
	vkCmdCopyQueryPoolResults(cmds[1], qp, 5, 1, buf, 0, 16, fb | VK_QUERY_RESULT_WAIT_BIT);
	vkCmdCopyQueryPoolResults(cmds[1], qp, 2, 1, buf, 16, 16, fb | VK_QUERY_RESULT_WAIT_BIT);
	vkCmdCopyQueryPoolResults(cmds[1], qp, 3, 2, buf, 32, 16, fb);
	vkCmdCopyQueryPoolResults(cmds[1], qp, 5, 1, buf, 64, 8, VK_QUERY_RESULT_WITH_AVAILABILITY_BIT | VK_QUERY_RESULT_WAIT_BIT);
	VkMemoryBarrier mb = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
		.dstAccessMask = VK_ACCESS_HOST_READ_BIT };
	vkCmdPipelineBarrier(cmds[1], VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
	CK(vkEndCommandBuffer(cmds[1]));
	si.pCommandBuffers = &cmds[1];
	CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
	CK(vkQueueWaitIdle(queue));

	const uint64_t *r64 = (const uint64_t *)map;
	const uint32_t *r32 = (const uint32_t *)(map + 64);
	uint64_t host = 0;
	CK(vkGetQueryPoolResults(dev, qp, 5, 1, sizeof(host), &host, 8, VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT));
	int fails = 0;
	struct { const char *what; int ok; } checks[] = {
		{ "query 5 (triangle): available, samples > 0, same as vkGetQueryPoolResults", r64[1] == 1 && r64[0] > 0 && r64[0] == host },
		{ "query 2 (no draws): available, 0 samples", r64[3] == 1 && r64[2] == 0 },
		{ "queries 3, 4 (never begun): unavailable, results untouched",
		  r64[5] == 0 && r64[7] == 0 && r64[4] == 0xababababababababull && r64[6] == 0xababababababababull },
		{ "query 5, 32-bit: available, same samples", r32[1] == 1 && r32[0] == (uint32_t)host },
	};
	for (size_t i = 0; i < sizeof(checks) / sizeof(checks[0]); i++) {
		printf("%-4s occlusion query copy from a later command buffer, %s (samples %llu, available %llu)\n",
		       checks[i].ok ? "OK" : "FAIL", checks[i].what, (unsigned long long)r64[0], (unsigned long long)r64[1]);
		fails += !checks[i].ok;
	}
	if (fails) { printf("queries: %d failure(s)\n", fails); return 1; }
	return 0;
}
