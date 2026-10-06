/*
 * Small host-visible allocations the way virglrenderer's Venus backend makes them (STEAMAC-G: Left 4 Dead 2's
 * GPU context died after "proxy: invalid reply for blob" and "vkAllocateMemory failed: VkResult -1, size 16384,
 * memory type 1").
 *
 * vkr backs every host-visible or exportable guest allocation with a POSIX shm object imported as host memory
 * (VK_EXT_external_memory_host): the allocation keeps the shm fd, the exported blob is a dup of it and the blob's
 * resource keeps another dup (modelled here; libkrun keeps a fourth, its export of the blob). Each live mapped
 * allocation costs these file descriptors of the one VMM process (render server and workers are threads in it), and
 * a Finder-launched app starts with a soft RLIMIT_NOFILE of 256. At the limit the blob export's dup fails first (the
 * render server replies without an fd: "invalid reply for blob"), then shm_open (vkAllocateMemory failed with
 * VK_ERROR_OUT_OF_HOST_MEMORY).
 *
 * 1. Soft limit 256 (a Finder launch): Venus-style allocations of 16 KiB in the host-visible memory type until
 *    shm_open or dup fails with EMFILE, which must happen before 256 / 3 allocations; the driver must never be
 *    the one that fails.
 * 2. The limit steamac-vm raises itself to (min(hard limit, kern.maxfilesperproc)): 8192 live Venus-style
 *    allocations with a buffer bound to each, then 20000 rounds of free + allocate (a game streaming small
 *    buffers), and 8192 live plain allocations of the host-visible type (the driver's own memory). Everything must
 *    succeed and every fd be closed again once the memory is freed.
 */
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

#define SIZE 16384
#define LIVE 8192
#define CHURN 20000

static VkDevice dev;
static uint32_t host_type;
static PFN_vkGetMemoryHostPointerPropertiesEXT get_host_ptr_props;

/* one guest allocation as vkr makes it */
struct alloc {
	int shm_fd, blob_fd, res_fd;
	void *ptr;
	VkDeviceMemory mem;
	VkBuffer buf;
};

static int open_fds(void)
{
	/* without a buffer PROC_PIDLISTFDS only estimates (with slack) */
	static struct proc_fdinfo fds[LIVE * 4];
	return proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fds, sizeof(fds)) / (int)PROC_PIDLISTFD_SIZE;
}

static void set_soft_limit(rlim_t cur)
{
	struct rlimit rl;
	getrlimit(RLIMIT_NOFILE, &rl);
	rl.rlim_cur = cur;
	if (setrlimit(RLIMIT_NOFILE, &rl)) {
		printf("FAIL setrlimit(RLIMIT_NOFILE, %llu): %s\n", (unsigned long long)cur, strerror(errno));
		exit(1);
	}
}

/* what steamac-vm does at startup */
static rlim_t raised_limit(void)
{
	struct rlimit rl;
	getrlimit(RLIMIT_NOFILE, &rl);
	int per_proc = 0;
	size_t len = sizeof(per_proc);
	sysctlbyname("kern.maxfilesperproc", &per_proc, &len, NULL, 0);
	return rl.rlim_max < (rlim_t)per_proc ? rl.rlim_max : (rlim_t)per_proc;
}

static int shm_create(void)
{
	char name[32];
	for (unsigned i = 0;; i++) {
		snprintf(name, sizeof(name), "/repro-%d-%x-%x", getpid(), arc4random(), i);
		int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
		if (fd >= 0) {
			shm_unlink(name);
			if (ftruncate(fd, SIZE)) {
				close(fd);
				return -1;
			}
			return fd;
		}
		if (errno != EEXIST)
			return -1;
	}
}

/* 0 on success, else the errno of the failed fd operation; driver failures exit */
static int venus_alloc(struct alloc *a)
{
	*a = (struct alloc){ .shm_fd = -1, .blob_fd = -1, .res_fd = -1 };
	a->shm_fd = shm_create();
	if (a->shm_fd < 0)
		return errno;
	a->ptr = mmap(NULL, SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, a->shm_fd, 0);
	if (a->ptr == MAP_FAILED) {
		printf("FAIL mmap: %s\n", strerror(errno));
		exit(1);
	}
	VkMemoryHostPointerPropertiesEXT hp = { VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT };
	CK(get_host_ptr_props(dev, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, a->ptr, &hp));
	if (!(hp.memoryTypeBits & (1u << host_type))) {
		printf("FAIL host pointer memory types 0x%x lack type %u\n", hp.memoryTypeBits, host_type);
		exit(1);
	}
	VkImportMemoryHostPointerInfoEXT import = { VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT,
		.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, .pHostPointer = a->ptr };
	VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &import, SIZE, host_type };
	CK(vkAllocateMemory(dev, &ai, NULL, &a->mem));
	VkExternalMemoryBufferCreateInfo ext = { VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO,
		.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT };
	VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, &ext, .size = SIZE,
		.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
	CK(vkCreateBuffer(dev, &bci, NULL, &a->buf));
	CK(vkBindBufferMemory(dev, a->buf, a->mem, 0));
	/* the guest maps it: the blob is exported, its resource keeps a dup */
	a->blob_fd = fcntl(a->shm_fd, F_DUPFD_CLOEXEC, 0);
	if (a->blob_fd < 0)
		return errno;
	a->res_fd = fcntl(a->shm_fd, F_DUPFD_CLOEXEC, 0);
	if (a->res_fd < 0)
		return errno;
	memset(a->ptr, 0x5a, 64);
	return 0;
}

static void venus_free(struct alloc *a)
{
	if (a->buf)
		vkDestroyBuffer(dev, a->buf, NULL);
	if (a->mem)
		vkFreeMemory(dev, a->mem, NULL);
	if (a->ptr && a->ptr != MAP_FAILED)
		munmap(a->ptr, SIZE);
	if (a->res_fd >= 0)
		close(a->res_fd);
	if (a->blob_fd >= 0)
		close(a->blob_fd);
	if (a->shm_fd >= 0)
		close(a->shm_fd);
	*a = (struct alloc){ .shm_fd = -1, .blob_fd = -1, .res_fd = -1 };
}

int main(void)
{
	VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
	VkInstance inst;
	CK(vkCreateInstance(&ici, NULL, &inst));
	VkPhysicalDevice pd;
	uint32_t n = 1;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) { printf("FAIL no physical device\n"); return 1; }
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	host_type = UINT32_MAX;
	for (uint32_t i = 0; i < mp.memoryTypeCount && host_type == UINT32_MAX; i++)
		if (mp.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
			host_type = i;
	if (host_type == UINT32_MAX) { printf("FAIL no host-visible memory type\n"); return 1; }
	const char *exts[] = { VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME };
	float prio = 1;
	VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &prio };
	VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
		.enabledExtensionCount = 1, .ppEnabledExtensionNames = exts };
	CK(vkCreateDevice(pd, &dci, NULL, &dev));
	get_host_ptr_props = (PFN_vkGetMemoryHostPointerPropertiesEXT)vkGetDeviceProcAddr(dev, "vkGetMemoryHostPointerPropertiesEXT");
	if (!get_host_ptr_props) { printf("FAIL no vkGetMemoryHostPointerPropertiesEXT\n"); return 1; }

	static struct alloc allocs[LIVE];

	/* 1. a Finder launch's soft limit */
	set_soft_limit(256);
	int base = open_fds();
	int count = 0, err = 0;
	while (count < LIVE && !(err = venus_alloc(&allocs[count])))
		count++;
	if (err != EMFILE || count >= 256 / 3) {
		printf("FAIL limit 256 (%d fds open before): %d Venus-style allocations, then %s\n", base, count,
		       err ? strerror(err) : "no failure");
		return 1;
	}
	printf("OK   limit 256 (%d fds open before): %d Venus-style %d KiB allocations of memory type %u, then %s\n",
	       base, count, SIZE / 1024, host_type, strerror(err));
	for (int i = 0; i <= count; i++)
		venus_free(&allocs[i]);
	if (open_fds() != base) { printf("FAIL %d fds open after freeing, %d before\n", open_fds(), base); return 1; }

	/* 2. the limit steamac-vm raises itself to */
	const rlim_t limit = raised_limit();
	set_soft_limit(limit);
	for (int i = 0; i < LIVE; i++) {
		if ((err = venus_alloc(&allocs[i]))) {
			printf("FAIL limit %llu: Venus-style allocation %d: %s\n", (unsigned long long)limit, i, strerror(err));
			return 1;
		}
	}
	const int live_fds = open_fds() - base;
	for (int r = 0; r < CHURN; r++) {
		struct alloc *a = &allocs[arc4random_uniform(LIVE)];
		venus_free(a);
		if ((err = venus_alloc(a))) {
			printf("FAIL churn round %d: %s\n", r, strerror(err));
			return 1;
		}
	}
	for (int i = 0; i < LIVE; i++)
		venus_free(&allocs[i]);
	if (open_fds() != base) { printf("FAIL %d fds open after freeing, %d before\n", open_fds(), base); return 1; }
	printf("OK   limit %llu: %d live Venus-style allocations (%d fds), %d free + allocate rounds, all fds closed\n",
	       (unsigned long long)limit, LIVE, live_fds, CHURN);

	static VkDeviceMemory plain[LIVE];
	for (int i = 0; i < LIVE; i++) {
		VkMemoryAllocateInfo ai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = SIZE, .memoryTypeIndex = host_type };
		CK(vkAllocateMemory(dev, &ai, NULL, &plain[i]));
	}
	for (int i = 0; i < LIVE; i++)
		vkFreeMemory(dev, plain[i], NULL);
	printf("OK   %d live plain %d KiB allocations of memory type %u\n", LIVE, SIZE / 1024, host_type);

	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(inst, NULL);
	return 0;
}
