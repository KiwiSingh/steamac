/*
 * Device loss must be reported on stderr (STEAMAC-G: an M4 Max lost its KosmicKrisp device and the
 * guest context died with only "vkr: vkQueueSubmit resulted in CS error").
 *
 * Mesa's runtime reports vk_device_set_lost / vk_queue_set_lost through __vk_errorf, which a release
 * build only prints in debug builds or to a debug messenger; KosmicKrisp loses its device that way on
 * a failed Metal command buffer. A Metal failure cannot be provoked on demand (Apple GPUs drop stray
 * stores, and a spinning shader was not stopped within 30 s), so this takes the runtime's queue-loss
 * path: a vkQueueSubmit signalling a timeline semaphore with value 0 loses the device.
 *
 * Child process (argv[1] == "child"): the submit must return VK_ERROR_DEVICE_LOST, and so must the
 * next one. Parent: runs the child with stderr captured; the child's stderr must name the loss
 * ("VK_ERROR_DEVICE_LOST" and the runtime's reason).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static int child(void)
{
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	uint32_t n = 1;
	VkPhysicalDevice pd;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	VkPhysicalDeviceVulkan12Features v12 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .timelineSemaphore = VK_TRUE };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &v12, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
	VkDevice dev;
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	VkQueue q;
	vkGetDeviceQueue(dev, 0, 0, &q);
	VkSemaphoreTypeCreateInfo stci = { VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO, .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE };
	VkSemaphoreCreateInfo sci = { VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, &stci };
	VkSemaphore sem;
	CK(vkCreateSemaphore(dev, &sci, NULL, &sem));
	uint64_t zero = 0;
	VkTimelineSemaphoreSubmitInfo tsi = { VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO, .signalSemaphoreValueCount = 1,
		.pSignalSemaphoreValues = &zero };
	VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, &tsi, .signalSemaphoreCount = 1, .pSignalSemaphores = &sem };
	VkResult r = vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE);
	printf("%-4s submit signalling timeline value 0: VkResult %d (expected VK_ERROR_DEVICE_LOST)\n",
	       r == VK_ERROR_DEVICE_LOST ? "OK" : "FAIL", r);
	VkSubmitInfo empty = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
	VkResult r2 = vkQueueSubmit(q, 1, &empty, VK_NULL_HANDLE);
	printf("%-4s next submit: VkResult %d (expected VK_ERROR_DEVICE_LOST)\n", r2 == VK_ERROR_DEVICE_LOST ? "OK" : "FAIL", r2);
	fflush(stdout);
	/* the device is lost: exit without tearing it down */
	return r != VK_ERROR_DEVICE_LOST || r2 != VK_ERROR_DEVICE_LOST;
}

int main(int argc, char **argv)
{
	if (argc > 1 && !strcmp(argv[1], "child"))
		return child();

	char cmd[4096];
	snprintf(cmd, sizeof(cmd), "'%s' child 3>&1 1>&2 2>&3", argv[0]);
	FILE *p = popen(cmd, "r");
	if (!p) { printf("FAIL popen\n"); return 1; }
	char err[8192] = "";
	size_t len = fread(err, 1, sizeof(err) - 1, p);
	err[len] = '\0';
	int status = pclose(p);
	int fails = status != 0;
	if (status) printf("FAIL child exit status %d\n", status);
	int named = strstr(err, "VK_ERROR_DEVICE_LOST") && strstr(err, "Tried to signal a timeline with value 0");
	printf("%-4s device loss reported on stderr\n", named ? "OK" : "FAIL");
	if (!named) printf("     child stderr: \"%s\"\n", err);
	fails += !named;
	if (fails) { printf("device_lost: %d failure(s)\n", fails); return 1; }
	return 0;
}
