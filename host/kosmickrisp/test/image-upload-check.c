#define _POSIX_C_SOURCE 200112L
#include <stdio.h>
#include <stdlib.h>
#include <vulkan/vulkan.h>
#define CHECK(call)                                                            \
  do {                                                                         \
    VkResult r = (call);                                                       \
    if (r != VK_SUCCESS) {                                                     \
      fprintf(stderr, "%s: %d\n", #call, r);                                   \
      return 1;                                                                \
    }                                                                          \
  } while (0)
int main(void) {
  VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                           .apiVersion = VK_API_VERSION_1_3};
  VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                              .pApplicationInfo = &app};
  VkInstance instance;
  CHECK(vkCreateInstance(&ici, NULL, &instance));
  uint32_t count = 1;
  VkPhysicalDevice physical;
  CHECK(vkEnumeratePhysicalDevices(instance, &count, &physical));
  if (!count)
    return 1;
  uint32_t n = 0;
  vkGetPhysicalDeviceQueueFamilyProperties(physical, &n, NULL);
  VkQueueFamilyProperties *families = calloc(n, sizeof(*families));
  vkGetPhysicalDeviceQueueFamilyProperties(physical, &n, families);
  uint32_t family = 0;
  while (family < n && !(families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT))
    family++;
  free(families);
  if (family == n)
    return 1;
  float priority = 1;
  VkDeviceQueueCreateInfo qci = {.sType =
                                     VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                 .queueFamilyIndex = family,
                                 .queueCount = 1,
                                 .pQueuePriorities = &priority};
  const char *ext = "VK_EXT_external_memory_host";
  VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                            .queueCreateInfoCount = 1,
                            .pQueueCreateInfos = &qci,
                            .enabledExtensionCount = 1,
                            .ppEnabledExtensionNames = &ext};
  VkDevice device;
  CHECK(vkCreateDevice(physical, &dci, NULL, &device));
  VkPhysicalDeviceExternalMemoryHostPropertiesEXT hp = {
      .sType =
          VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT};
  VkPhysicalDeviceProperties2 props = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &hp};
  vkGetPhysicalDeviceProperties2(physical, &props);
  VkExternalMemoryBufferCreateInfo external = {
      .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO,
      .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT};
  VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                            .pNext = &external,
                            .size = 65536,
                            .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT |
                                     VK_BUFFER_USAGE_TRANSFER_SRC_BIT};
  VkBuffer buffer;
  CHECK(vkCreateBuffer(device, &bci, NULL, &buffer));
  VkMemoryRequirements req;
  vkGetBufferMemoryRequirements(device, buffer, &req);
  size_t alignment = hp.minImportedHostPointerAlignment;
  if (alignment < req.alignment)
    alignment = req.alignment;
  if (alignment < sizeof(void *))
    alignment = sizeof(void *);
  size_t size = (req.size + alignment - 1) / alignment * alignment;
  void *pointer = NULL;
  if (posix_memalign(&pointer, alignment, size))
    return 1;
  PFN_vkGetMemoryHostPointerPropertiesEXT pointerProperties =
      (PFN_vkGetMemoryHostPointerPropertiesEXT)vkGetDeviceProcAddr(
          device, "vkGetMemoryHostPointerPropertiesEXT");
  if (!pointerProperties)
    return 1;
  VkMemoryHostPointerPropertiesEXT pp = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT};
  CHECK(pointerProperties(
      device, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, pointer,
      &pp));
  VkPhysicalDeviceMemoryProperties mp;
  vkGetPhysicalDeviceMemoryProperties(physical, &mp);
  /* An exported WSI buffer can be allocated before its fd is requested.
   * Every advertised buffer type must therefore support host-pointer sharing.
   */
  for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
    if ((req.memoryTypeBits & (1u << i)) &&
        !(mp.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
      fprintf(stderr, "Buffer requirements advertise unshareable type %u\n", i);
      return 1;
    }
  }
  uint32_t type = 0;
  while (type < mp.memoryTypeCount &&
         (!(req.memoryTypeBits & pp.memoryTypeBits & (1u << type)) ||
          !(mp.memoryTypes[type].propertyFlags &
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)))
    type++;
  if (type == mp.memoryTypeCount)
    return 1;
  VkImportMemoryHostPointerInfoEXT import = {
      .sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT,
      .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT,
      .pHostPointer = pointer};
  VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                              .pNext = &import,
                              .allocationSize = size,
                              .memoryTypeIndex = type};
  VkDeviceMemory memory;
  CHECK(vkAllocateMemory(device, &mai, NULL, &memory));
  CHECK(vkBindBufferMemory(device, buffer, memory, 0));
  void *mapped;
  CHECK(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped));
  /* Match Venus: host-visible allocations are imported as host pointers. */
  VkImageCreateInfo imageInfo = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                                 .imageType = VK_IMAGE_TYPE_2D,
                                 .format = VK_FORMAT_R8G8B8A8_UNORM,
                                 .extent = {64, 64, 1},
                                 .mipLevels = 1,
                                 .arrayLayers = 1,
                                 .samples = VK_SAMPLE_COUNT_1_BIT,
                                 .tiling = VK_IMAGE_TILING_OPTIMAL,
                                 .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                                          VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                                 .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
  VkImageCreateInfo linearInfo = imageInfo;
  linearInfo.tiling = VK_IMAGE_TILING_LINEAR;
  VkImage linear;
  CHECK(vkCreateImage(device, &linearInfo, NULL, &linear));
  VkMemoryRequirements linearReq;
  vkGetImageMemoryRequirements(device, linear, &linearReq);
  if (!linearReq.memoryTypeBits)
    return 1;
  for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
    if ((linearReq.memoryTypeBits & (1u << i)) &&
        !(mp.memoryTypes[i].propertyFlags &
          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
      fprintf(stderr,
              "Linear scanout image offered non-shareable memory type %u\n", i);
      return 1;
    }
  vkDestroyImage(device, linear, NULL);
  VkImage image;
  CHECK(vkCreateImage(device, &imageInfo, NULL, &image));
  VkMemoryRequirements imageReq;
  vkGetImageMemoryRequirements(device, image, &imageReq);
  uint32_t imageType = 0;
  while (imageType < mp.memoryTypeCount &&
         !(imageReq.memoryTypeBits & (1u << imageType)))
    imageType++;
  if (imageType == mp.memoryTypeCount)
    return 1;
  void *imagePointer = NULL;
  VkImportMemoryHostPointerInfoEXT imageImport = {
      .sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT,
      .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT};
  VkMemoryAllocateInfo imageAlloc = {.sType =
                                         VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                     .allocationSize = imageReq.size,
                                     .memoryTypeIndex = imageType};
  if (mp.memoryTypes[imageType].propertyFlags &
      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) {
    size_t align = hp.minImportedHostPointerAlignment;
    if (align < imageReq.alignment)
      align = imageReq.alignment;
    size_t allocSize = (imageReq.size + align - 1) / align * align;
    if (posix_memalign(&imagePointer, align, allocSize))
      return 1;
    imageImport.pHostPointer = imagePointer;
    imageAlloc.pNext = &imageImport;
    imageAlloc.allocationSize = allocSize;
  }
  VkDeviceMemory imageMemory;
  CHECK(vkAllocateMemory(device, &imageAlloc, NULL, &imageMemory));
  CHECK(vkBindImageMemory(device, image, imageMemory, 0));
  VkCommandPoolCreateInfo pci = {.sType =
                                     VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                 .queueFamilyIndex = family};
  VkCommandPool pool;
  CHECK(vkCreateCommandPool(device, &pci, NULL, &pool));
  VkCommandBufferAllocateInfo cai = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = pool,
      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = 1};
  VkCommandBuffer command;
  CHECK(vkAllocateCommandBuffers(device, &cai, &command));
  VkCommandBufferBeginInfo begin = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
  CHECK(vkBeginCommandBuffer(command, &begin));
  vkCmdFillBuffer(command, buffer, 0, 65536, 0x1234abcd);
  VkMemoryBarrier uploadBarrier = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
      .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT};
  VkImageMemoryBarrier imageBarrier = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
      .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
      .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .image = image,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
  vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                       VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &uploadBarrier, 0,
                       NULL, 1, &imageBarrier);
  VkBufferImageCopy copy = {
      .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
      .imageExtent = {64, 64, 1}};
  vkCmdCopyBufferToImage(command, buffer, image,
                         VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
  imageBarrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
  imageBarrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
  imageBarrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
  imageBarrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
  vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                       VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1,
                       &imageBarrier);
  vkCmdFillBuffer(command, buffer, 32768, 16384, 0);
  vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                       VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &uploadBarrier, 0,
                       NULL, 0, NULL);
  copy.bufferOffset = 32768;
  vkCmdCopyImageToBuffer(command, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                         buffer, 1, &copy);
  VkMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                             .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                             .dstAccessMask = VK_ACCESS_HOST_READ_BIT};
  vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                       VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &barrier, 0, NULL, 0,
                       NULL);
  CHECK(vkEndCommandBuffer(command));
  VkQueue queue;
  vkGetDeviceQueue(device, family, 0, &queue);
  VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                         .commandBufferCount = 1,
                         .pCommandBuffers = &command};
  CHECK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE));
  CHECK(vkQueueWaitIdle(queue));
  VkMappedMemoryRange range = {.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                               .memory = memory,
                               .offset = 0,
                               .size = VK_WHOLE_SIZE};
  CHECK(vkInvalidateMappedMemoryRanges(device, 1, &range));
  for (size_t i = 0; i < 65536 / 4; i++)
    if (((uint32_t *)mapped)[i] != 0x1234abcd ||
        ((uint32_t *)pointer)[i] != 0x1234abcd) {
      fprintf(stderr, "GPU data mismatch at %zu\n", i);
      return 1;
    }
  printf("PASS: %s device, imported host memory, buffer-to-optimal-texture "
         "upload, texture readback and shared-memory visibility\n",
         props.properties.deviceName);
  vkDestroyCommandPool(device, pool, NULL);
  vkDestroyImage(device, image, NULL);
  vkFreeMemory(device, imageMemory, NULL);
  free(imagePointer);
  vkUnmapMemory(device, memory);
  vkDestroyBuffer(device, buffer, NULL);
  vkFreeMemory(device, memory, NULL);
  free(pointer);
  vkDestroyDevice(device, NULL);
  vkDestroyInstance(instance, NULL);
  return 0;
}
