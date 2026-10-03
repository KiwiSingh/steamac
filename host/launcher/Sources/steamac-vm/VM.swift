import CKrun
import Darwin
import Foundation

struct KrunError: Error, CustomStringConvertible {
    let call: String
    let code: Int32
    var description: String { "\(call) failed: \(code) (\(String(cString: strerror(-code))))" }
}

@discardableResult
func krun(_ name: String, _ r: Int32) throws -> Int32 {
    if r < 0 { throw KrunError(call: name, code: r) }
    return r
}

/// Input devices handed to the window (nil in headless mode).
struct VMInputs {
    let keyboard: InputDevice
    let tablet: InputDevice
    let mouse: InputDevice
    let gamepad: InputDevice?
}

/// libkrun context: configuration (boot contract) and the VMM thread.
final class VM {
    let ctx: UInt32
    private(set) var shutdownFd: Int32 = -1
    private(set) var running = false

    init(options o: Options, display: DisplayBackend, console: Console, inputs: VMInputs?, network: Gvproxy?) throws {
        try krun("krun_init_log", krun_init_log(KRUN_LOG_TARGET_DEFAULT, o.krunLogLevel, UInt32(KRUN_LOG_STYLE_AUTO), 0))
        ctx = UInt32(try krun("krun_create_ctx", krun_create_ctx()))
        try krun("krun_set_vm_config", krun_set_vm_config(ctx, UInt8(o.cpus), UInt32(o.memMiB)))

        // No TSI/vsock in this guest; hvc0 = our pty (explicit console instead of the implicit
        // stdio one, so console output also works when stdout is a pipe/file).
        try krun("krun_disable_implicit_vsock", krun_disable_implicit_vsock(ctx))
        try krun("krun_disable_implicit_console", krun_disable_implicit_console(ctx))
        let con = try krun("krun_add_virtio_console_multiport", krun_add_virtio_console_multiport(ctx))
        try krun("krun_add_console_port_tty", krun_add_console_port_tty(ctx, UInt32(con), "", console.slaveFd))

        try krun("krun_set_kernel", krun_set_kernel(ctx, o.kernel, STEAMAC_KERNEL_FORMAT_RAW, o.initrd, o.cmdline))

        for (i, d) in o.disks.enumerated() {
            let id = "vd" + String(UnicodeScalar(UInt8(97 + i)))
            try krun("krun_add_disk2(\(d.path))", krun_add_disk2(ctx, id, d.path, STEAMAC_DISK_FORMAT_RAW, d.readOnly))
            log("disk \(id): \(d.path)\(d.readOnly ? " (ro)" : "")")
        }

        // GPU: Venus only (no virgl GL), host-visible shm window for blobs.
        let flags = o.gpuFlags ?? (STEAMAC_VIRGL_VENUS | STEAMAC_VIRGL_NO_VIRGL)
        try krun("krun_set_gpu_options2", krun_set_gpu_options2(ctx, flags, UInt64(o.shmMiB) << 20))
        let did = UInt32(try krun("krun_add_display", krun_add_display(ctx, UInt32(o.displayWidth), UInt32(o.displayHeight))))
        try krun("krun_display_set_refresh_rate", krun_display_set_refresh_rate(ctx, did, UInt32(o.refreshRate)))
        var backend = display.makeCBackend()
        try krun("krun_set_display_backend", krun_set_display_backend(ctx, &backend, MemoryLayout<krun_display_backend>.size))

        if let inputs {
            guard krun_has_feature(UInt64(KRUN_FEATURE_INPUT)) == 1 else {
                throw OptionError("this libkrun was built without INPUT=1 (krun_has_feature(KRUN_FEATURE_INPUT) != 1); use --headless or the libkrun from work/out/host/lib")
            }
            try inputs.keyboard.attach(ctx: ctx)
            try inputs.tablet.attach(ctx: ctx)
            try inputs.mouse.attach(ctx: ctx)
            try inputs.gamepad?.attach(ctx: ctx)
        }

        if let network { try network.attach(ctx: ctx) }

        // macOS/aarch64: an eventfd wired to libkrun's gpio-keys device (graceful shutdown key).
        shutdownFd = krun_get_shutdown_eventfd(ctx)
        if shutdownFd < 0 { log("warning: krun_get_shutdown_eventfd: \(shutdownFd)"); shutdownFd = -1 }
    }

    /// Runs the VMM on a dedicated thread. libkrun exit()s the process when the guest stops.
    func start() {
        running = true
        let t = Thread { [ctx] in
            let r = krun_start_enter(ctx)
            fatal("krun_start_enter failed: \(r) (\(String(cString: strerror(-r))))")
        }
        t.name = "krun-vmm"
        t.stackSize = 16 << 20
        t.qualityOfService = .userInteractive
        t.start()
    }

    /// Press the guest power key (gpio-keys, KEY_RESTART in libkrun 1.19.6's FDT; systemd-logind
    /// shuts down and libkrun exits on PSCI SYSTEM_OFF/RESET). Returns false if unavailable.
    @discardableResult
    func requestShutdown() -> Bool {
        guard shutdownFd >= 0 else { return false }
        var one: UInt64 = 1
        return Darwin.write(shutdownFd, &one, 8) == 8
    }
}
