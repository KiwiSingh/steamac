// virtio-snd harness: boots the steamac guest like the launcher (kernel + initramfs, disks,
// Venus GPU with one headless display, hvc0 + fx.progress console ports, virtio-snd) without
// a network, a window or input devices, and takes commands on a FIFO while the VM runs:
//
//   type TEXT            write TEXT and a newline to the guest console (hvc0)
//   intr                 write Ctrl-C to the guest console
//   device UID|default   krun_snd_set_output_device (default = follow the system default)
//   volume GAIN [mute]   krun_snd_set_volume
//   buffer MS            krun_snd_set_buffer_ms
//   devices              list the CoreAudio output devices (UID, rate, IO buffer)
//
// `audio --list-devices` only lists the output devices. The guest console is copied to
// --console; libkrun logs (and STEAMAC_SND_TRACE / STEAMAC_SND_DUMP output) go to stderr.
// libkrun exits the process when the guest powers off.
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

#include <libkrun.h>
#include <libkrun_display.h>

static double start_time;

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void say(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[audio %8.3f] ", now() - start_time);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static void die(const char *what, long r)
{
    say("%s failed: %ld", what, r);
    exit(1);
}

#define KRUN(call)                                                                                 \
    do {                                                                                           \
        int32_t r_ = (call);                                                                       \
        if (r_ < 0)                                                                                \
            die(#call, r_);                                                                        \
    } while (0)

// --- CoreAudio output devices
static bool device_prop(AudioObjectID dev, AudioObjectPropertySelector sel,
                        AudioObjectPropertyScope scope, void *out, UInt32 size)
{
    AudioObjectPropertyAddress a = {sel, scope, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, out) == noErr;
}

static void cfstr(CFStringRef s, char *buf, size_t len)
{
    buf[0] = 0;
    if (s) {
        CFStringGetCString(s, buf, (CFIndex)len, kCFStringEncodingUTF8);
        CFRelease(s);
    }
}

static void list_devices(void)
{
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) != noErr)
        return;
    AudioObjectID *ids = malloc(size);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids);
    AudioObjectID def = 0;
    device_prop(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice,
                kAudioObjectPropertyScopeGlobal, &def, sizeof(def));
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) {
        AudioObjectPropertyAddress s = {kAudioDevicePropertyStreams,
                                        kAudioObjectPropertyScopeOutput,
                                        kAudioObjectPropertyElementMain};
        UInt32 ssize = 0;
        if (AudioObjectGetPropertyDataSize(ids[i], &s, 0, NULL, &ssize) != noErr || !ssize)
            continue;
        CFStringRef uid_s = NULL, name_s = NULL;
        char uid[256], name[256];
        device_prop(ids[i], kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal,
                    &uid_s, sizeof(uid_s));
        device_prop(ids[i], kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &name_s,
                    sizeof(name_s));
        cfstr(uid_s, uid, sizeof(uid));
        cfstr(name_s, name, sizeof(name));
        Float64 rate = 0;
        UInt32 frames = 0, safety = 0;
        device_prop(ids[i], kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                    &rate, sizeof(rate));
        device_prop(ids[i], kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput,
                    &frames, sizeof(frames));
        device_prop(ids[i], kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput,
                    &safety, sizeof(safety));
        say("output device %s'%s' uid=%s rate=%.0f io=%u safety=%u", ids[i] == def ? "*" : "",
            name, uid, rate, frames, safety);
    }
    free(ids);
}

// --- headless display: frames are accepted and dropped
static uint8_t *frame;
static size_t frame_size;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static int32_t disp_create(void **instance, const void *userdata, const void *reserved)
{
    (void)userdata;
    (void)reserved;
    *instance = NULL;
    return 0;
}

static int32_t disp_configure(void *instance, uint32_t id, uint32_t dw, uint32_t dh, uint32_t w,
                              uint32_t h, uint32_t fmt)
{
    (void)instance;
    (void)dw;
    (void)dh;
    (void)fmt;
    if (id != 0)
        return KRUN_DISPLAY_ERR_INVALID_SCANOUT_ID;
    pthread_mutex_lock(&lock);
    free(frame);
    frame_size = (size_t)w * h * 4;
    frame = calloc(frame_size, 1);
    pthread_mutex_unlock(&lock);
    return 0;
}

static int32_t disp_disable(void *instance, uint32_t id)
{
    (void)instance;
    (void)id;
    return 0;
}

static int32_t disp_alloc(void *instance, uint32_t id, uint8_t **buffer, size_t *size)
{
    (void)instance;
    if (id != 0)
        return KRUN_DISPLAY_ERR_INVALID_SCANOUT_ID;
    pthread_mutex_lock(&lock);
    *buffer = frame;
    *size = frame_size;
    pthread_mutex_unlock(&lock);
    return 0;
}

static int32_t disp_present(void *instance, uint32_t id, uint32_t frame_id,
                            const struct krun_rect *damage)
{
    (void)instance;
    (void)frame_id;
    (void)damage;
    return id == 0 ? 0 : KRUN_DISPLAY_ERR_INVALID_SCANOUT_ID;
}

// --- control FIFO
static uint32_t ctx;
static int console_master = -1;

static void console_write(const char *s, size_t len)
{
    while (len) {
        ssize_t n = write(console_master, s, len);
        if (n <= 0)
            return;
        s += n;
        len -= (size_t)n;
    }
}

static void *control_thread(void *arg)
{
    const char *fifo = arg;
    // O_RDWR: never sees EOF when a writer closes.
    FILE *f = fopen(fifo, "r+");
    if (!f) {
        say("cannot open %s: %s", fifo, strerror(errno));
        return NULL;
    }
    char line[4096];
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\n")] = 0;
        char arg1[4000];
        float gain;
        unsigned ms;
        if (!strncmp(line, "type ", 5)) {
            console_write(line + 5, strlen(line + 5));
            console_write("\n", 1);
        } else if (!strcmp(line, "intr")) {
            console_write("\003", 1);
        } else if (sscanf(line, "device %3999s", arg1) == 1) {
            bool def = !strcmp(arg1, "default");
            int32_t r = krun_snd_set_output_device(ctx, def ? NULL : arg1);
            say("krun_snd_set_output_device(%s) = %d", def ? "NULL" : arg1, r);
        } else if (sscanf(line, "volume %f", &gain) == 1) {
            bool mute = strstr(line, "mute") != NULL;
            int32_t r = krun_snd_set_volume(ctx, gain, mute);
            say("krun_snd_set_volume(%.2f, %s) = %d", gain, mute ? "mute" : "unmuted", r);
        } else if (sscanf(line, "buffer %u", &ms) == 1) {
            int32_t r = krun_snd_set_buffer_ms(ctx, ms);
            say("krun_snd_set_buffer_ms(%u) = %d", ms, r);
        } else if (!strcmp(line, "devices")) {
            list_devices();
        } else {
            say("unknown command: %s", line);
        }
    }
    return NULL;
}

// --- hvc0: a pty whose master is copied to the console log
static void *console_thread(void *arg)
{
    int out = *(int *)arg;
    char buf[4096];
    ssize_t n;
    while ((n = read(console_master, buf, sizeof(buf))) > 0)
        if (write(out, buf, (size_t)n) != n)
            break;
    return NULL;
}

static void usage(void)
{
    fprintf(stderr,
            "usage: audio --kernel IMAGE --initrd CPIO --disk PATH[:ro]... --console LOG\n"
            "             --control FIFO [--cmdline STR] [--cpus N] [--mem MiB] [--shm-mib MiB]\n"
            "             [--log-level 0-5]\n"
            "       audio --list-devices\n");
    exit(2);
}

int main(int argc, char **argv)
{
    start_time = now();
    if (argc == 2 && !strcmp(argv[1], "--list-devices")) {
        list_devices();
        return 0;
    }
    const char *kernel = NULL, *initrd = NULL, *console = NULL, *control = NULL;
    const char *cmdline = "console=hvc0 loglevel=4 rootwait";
    const char *disks[8];
    int ndisks = 0;
    unsigned cpus = 8, mem = 16384, shm = 8192, level = KRUN_LOG_LEVEL_INFO;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!v)
            usage();
        i++;
        if (!strcmp(a, "--kernel"))
            kernel = v;
        else if (!strcmp(a, "--initrd"))
            initrd = v;
        else if (!strcmp(a, "--cmdline"))
            cmdline = v;
        else if (!strcmp(a, "--disk") && ndisks < 8)
            disks[ndisks++] = v;
        else if (!strcmp(a, "--console"))
            console = v;
        else if (!strcmp(a, "--control"))
            control = v;
        else if (!strcmp(a, "--cpus"))
            cpus = (unsigned)atoi(v);
        else if (!strcmp(a, "--mem"))
            mem = (unsigned)atoi(v);
        else if (!strcmp(a, "--shm-mib"))
            shm = (unsigned)atoi(v);
        else if (!strcmp(a, "--log-level"))
            level = (unsigned)atoi(v);
        else
            usage();
    }
    if (!kernel || !initrd || !ndisks || !console || !control)
        usage();

    KRUN(krun_init_log(KRUN_LOG_TARGET_DEFAULT, level, KRUN_LOG_STYLE_AUTO, 0));
    int32_t c = krun_create_ctx();
    if (c < 0)
        die("krun_create_ctx", c);
    ctx = (uint32_t)c;
    KRUN(krun_set_vm_config(ctx, (uint8_t)cpus, mem));
    KRUN(krun_disable_implicit_vsock(ctx));
    KRUN(krun_disable_implicit_console(ctx));

    int con = krun_add_virtio_console_multiport(ctx);
    if (con < 0)
        die("krun_add_virtio_console_multiport", con);
    int slave;
    if (openpty(&console_master, &slave, NULL, NULL, NULL) < 0)
        die("openpty", -errno);
    static int console_log;
    console_log = open(console, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (console_log < 0)
        die("open console log", -errno);
    pthread_t t;
    pthread_create(&t, NULL, console_thread, &console_log);
    KRUN(krun_add_console_port_tty(ctx, (uint32_t)con, "", slave));
    // The guest's progress agent writes boot progress here; nothing reads it but the sink.
    int progress_in[2];
    if (pipe(progress_in) < 0)
        die("pipe", -errno);
    KRUN(krun_add_console_port_inout(ctx, (uint32_t)con, "fx.progress", progress_in[0],
                                     open("/dev/null", O_WRONLY)));

    KRUN(krun_set_kernel(ctx, kernel, KRUN_KERNEL_FORMAT_RAW, initrd, cmdline));
    for (int i = 0; i < ndisks; i++) {
        char path[4096], id[4] = {'v', 'd', (char)('a' + i), 0};
        snprintf(path, sizeof(path), "%s", disks[i]);
        size_t len = strlen(path);
        bool ro = len > 3 && !strcmp(path + len - 3, ":ro");
        if (ro)
            path[len - 3] = 0;
        KRUN(krun_add_disk2(ctx, id, path, KRUN_DISK_FORMAT_RAW, ro));
    }

    KRUN(krun_set_gpu_options2(ctx, VIRGLRENDERER_VENUS | VIRGLRENDERER_NO_VIRGL,
                               (uint64_t)shm << 20));
    KRUN(krun_add_display(ctx, 1280, 800));
    struct krun_display_backend display = {
        .features = KRUN_DISPLAY_FEATURE_BASIC_FRAMEBUFFER,
        .create = disp_create,
        .vtable.basic_framebuffer = {
            .disable_scanout = disp_disable,
            .configure_scanout = disp_configure,
            .alloc_frame = disp_alloc,
            .present_frame = disp_present,
        },
    };
    KRUN(krun_set_display_backend(ctx, &display, sizeof(display)));
    KRUN(krun_set_snd_device(ctx, true));

    list_devices();
    pthread_create(&t, NULL, control_thread, (void *)control);
    say("booting");
    int32_t r = krun_start_enter(ctx);
    die("krun_start_enter", r);
}
