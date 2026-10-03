/* Load test for a Vulkan ICD inside a target root (stock SteamOS rootfs or the
 * fex-mesa graphics provider), run via chroot during verification.
 *
 *   vkprobe <icd.so>   dlopen(RTLD_NOW) the ICD and resolve its loader entry points,
 *                      then create an instance through the system libvulkan.so.1.
 *
 * Exit status: 0 when the ICD loads and exports the ICD interface, non-zero otherwise.
 * Instance/device results are informational (no virtio-gpu device exists at build time). */
#include <dlfcn.h>
#include <stdio.h>
#include <vulkan/vulkan.h>

typedef VkResult (VKAPI_PTR *PFN_negotiate)(uint32_t *);

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <icd.so>\n", argv[0]);
        return 64;
    }

    void *icd = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!icd) {
        fprintf(stderr, "FAIL dlopen %s: %s\n", argv[1], dlerror());
        return 1;
    }
    PFN_negotiate negotiate = (PFN_negotiate)dlsym(icd, "vk_icdNegotiateLoaderICDInterfaceVersion");
    void *gipa = dlsym(icd, "vk_icdGetInstanceProcAddr");
    if (!negotiate || !gipa) {
        fprintf(stderr, "FAIL %s does not export the ICD interface\n", argv[1]);
        return 1;
    }
    uint32_t version = 7;
    VkResult r = negotiate(&version);
    printf("OK dlopen %s: vk_icdNegotiateLoaderICDInterfaceVersion -> %d (interface %u)\n",
           argv[1], (int)r, version);

    void *loader = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!loader) {
        printf("loader: dlopen libvulkan.so.1 failed: %s\n", dlerror());
        return 0;
    }
    PFN_vkGetInstanceProcAddr get = (PFN_vkGetInstanceProcAddr)dlsym(loader, "vkGetInstanceProcAddr");
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)get(NULL, "vkCreateInstance");
    VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "vkprobe",
        .apiVersion = VK_API_VERSION_1_1,
    };
    VkInstanceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
    };
    VkInstance instance;
    r = create(&info, NULL, &instance);
    printf("loader: vkCreateInstance -> %d\n", (int)r);
    if (r != VK_SUCCESS)
        return 0;

    PFN_vkEnumeratePhysicalDevices enumerate =
        (PFN_vkEnumeratePhysicalDevices)get(instance, "vkEnumeratePhysicalDevices");
    PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)get(instance, "vkDestroyInstance");
    uint32_t count = 0;
    r = enumerate(instance, &count, NULL);
    printf("loader: vkEnumeratePhysicalDevices -> %d, %u device(s)\n", (int)r, count);
    destroy(instance, NULL);
    return 0;
}
