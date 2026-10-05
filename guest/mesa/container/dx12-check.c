/* Run inside SteamOS: test vkd3d-proton's baseline against guest-visible Venus.
 * Passing is a capability check, not a guarantee that a game or DXR works.
 * See https://github.com/HansKristian-Work/vkd3d-proton#drivers */
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int has(const VkExtensionProperties *e, uint32_t n, const char *name) {
    for (uint32_t i = 0; i < n; i++)
        if (!strcmp(e[i].extensionName, name)) return 1;
    return 0;
}
static int check(VkPhysicalDevice d, PFN_vkGetInstanceProcAddr get, VkInstance instance) {
    PFN_vkGetPhysicalDeviceFeatures2 features = (PFN_vkGetPhysicalDeviceFeatures2)get(instance, "vkGetPhysicalDeviceFeatures2");
    PFN_vkGetPhysicalDeviceProperties2 props = (PFN_vkGetPhysicalDeviceProperties2)get(instance, "vkGetPhysicalDeviceProperties2");
    PFN_vkEnumerateDeviceExtensionProperties extensions = (PFN_vkEnumerateDeviceExtensionProperties)get(instance, "vkEnumerateDeviceExtensionProperties");
    VkPhysicalDeviceRobustness2FeaturesEXT robust = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT};
    VkPhysicalDeviceVulkan12Features f12 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &robust};
    VkPhysicalDeviceVulkan11Features f11 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, .pNext = &f12};
    VkPhysicalDeviceFeatures2 f = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f11};
    VkPhysicalDeviceVulkan12Properties p12 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES};
    VkPhysicalDeviceProperties2 p = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &p12};
    features(d, &f); props(d, &p);
    uint32_t n = 0;
    if (extensions(d, NULL, &n, NULL) != VK_SUCCESS) return 1;
    VkExtensionProperties *e = calloc(n ? n : 1, sizeof(*e));
    if (!e) return 1;
    if (extensions(d, NULL, &n, e) != VK_SUCCESS) { free(e); return 1; }
    int missing = 0;
    printf("Device: %s (Vulkan %u.%u.%u)\n", p.properties.deviceName,
           VK_API_VERSION_MAJOR(p.properties.apiVersion), VK_API_VERSION_MINOR(p.properties.apiVersion),
           VK_API_VERSION_PATCH(p.properties.apiVersion));
#define REQUIRE(expr) do { if (!(expr)) { printf("MISSING: %s\n", #expr); missing++; } } while (0)
    REQUIRE(p.properties.apiVersion >= VK_API_VERSION_1_3);
    REQUIRE(f11.shaderDrawParameters);
    REQUIRE(f12.samplerMirrorClampToEdge);
    REQUIRE(f12.descriptorIndexing);
    REQUIRE(f12.shaderInputAttachmentArrayDynamicIndexing);
    REQUIRE(f12.shaderUniformTexelBufferArrayDynamicIndexing);
    REQUIRE(f12.shaderStorageTexelBufferArrayDynamicIndexing);
    REQUIRE(f12.shaderUniformBufferArrayNonUniformIndexing);
    REQUIRE(f12.shaderSampledImageArrayNonUniformIndexing);
    REQUIRE(f12.shaderStorageBufferArrayNonUniformIndexing);
    REQUIRE(f12.shaderStorageImageArrayNonUniformIndexing);
    REQUIRE(f12.shaderInputAttachmentArrayNonUniformIndexing);
    REQUIRE(f12.shaderUniformTexelBufferArrayNonUniformIndexing);
    REQUIRE(f12.shaderStorageTexelBufferArrayNonUniformIndexing);
    REQUIRE(f12.descriptorBindingUniformBufferUpdateAfterBind);
    REQUIRE(f12.descriptorBindingSampledImageUpdateAfterBind);
    REQUIRE(f12.descriptorBindingStorageImageUpdateAfterBind);
    REQUIRE(f12.descriptorBindingStorageBufferUpdateAfterBind);
    REQUIRE(f12.descriptorBindingUniformTexelBufferUpdateAfterBind);
    REQUIRE(f12.descriptorBindingStorageTexelBufferUpdateAfterBind);
    REQUIRE(f12.descriptorBindingUpdateUnusedWhilePending);
    REQUIRE(f12.descriptorBindingPartiallyBound);
    REQUIRE(f12.descriptorBindingVariableDescriptorCount);
    REQUIRE(f12.runtimeDescriptorArray);
    REQUIRE(p12.maxDescriptorSetUpdateAfterBindSamplers >= 1000000);
    REQUIRE(p12.maxDescriptorSetUpdateAfterBindSampledImages >= 1000000);
    REQUIRE(p12.maxDescriptorSetUpdateAfterBindStorageImages >= 1000000);
    REQUIRE(p12.maxDescriptorSetUpdateAfterBindStorageBuffers >= 1000000);
    REQUIRE(p12.maxPerStageDescriptorUpdateAfterBindSamplers >= 1000000);
    REQUIRE(p12.maxPerStageDescriptorUpdateAfterBindSampledImages >= 1000000);
    REQUIRE(p12.maxPerStageDescriptorUpdateAfterBindStorageImages >= 1000000);
    REQUIRE(p12.maxPerStageDescriptorUpdateAfterBindStorageBuffers >= 1000000);
    REQUIRE(has(e, n, "VK_EXT_robustness2"));
    REQUIRE(robust.robustBufferAccess2 && robust.robustImageAccess2 && robust.nullDescriptor);
    REQUIRE(p.properties.apiVersion >= VK_API_VERSION_1_4 || has(e, n, "VK_KHR_push_descriptor"));
    printf("Optional: image_view_min_lod=%d mutable_descriptor_type=%d descriptor_buffer=%d\n",
           has(e, n, "VK_EXT_image_view_min_lod"), has(e, n, "VK_EXT_mutable_descriptor_type"),
           has(e, n, "VK_EXT_descriptor_buffer"));
    free(e);
    printf("%s: vkd3d-proton baseline (validate games separately)\n", missing ? "FAIL" : "PASS");
    return missing != 0;
}
int main(void) {
    void *lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fprintf(stderr, "Vulkan loader: %s\n", dlerror()); return 1; }
    PFN_vkGetInstanceProcAddr get = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
    if (!get) return 1;
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)get(NULL, "vkCreateInstance");
    if (!create) return 1;
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "steamac-dx12-check", .apiVersion = VK_API_VERSION_1_3};
    VkInstanceCreateInfo ci = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkInstance instance;
    VkResult result = create(&ci, NULL, &instance);
    if (result != VK_SUCCESS) { fprintf(stderr, "vkCreateInstance: %d\n", result); return 1; }
    PFN_vkEnumeratePhysicalDevices enumerate = (PFN_vkEnumeratePhysicalDevices)get(instance, "vkEnumeratePhysicalDevices");
    PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)get(instance, "vkDestroyInstance");
    uint32_t n = 0; int passed = 0;
    if (enumerate(instance, &n, NULL) == VK_SUCCESS && n) {
        VkPhysicalDevice *devices = calloc(n, sizeof(*devices));
        if (devices && enumerate(instance, &n, devices) == VK_SUCCESS)
            for (uint32_t i = 0; i < n; i++) if (!check(devices[i], get, instance)) passed = 1;
        free(devices);
    } else fprintf(stderr, "No guest Vulkan device. Check Venus and the host ICD.\n");
    destroy(instance, NULL); dlclose(lib); return passed ? 0 : 1;
}
