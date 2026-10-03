import Foundation

struct DiskSpec {
    var path: String
    var readOnly: Bool
}

enum MouseMode: String {
    case absolute   // tablet only; Ctrl+Cmd+G grabs explicitly
    case capture    // a click in the window grabs the pointer (relative mouse)
}

struct Options {
    var kernel: String = ""
    var initrd: String?
    var cmdline = "console=hvc0 loglevel=4 rootwait"
    var disks: [DiskSpec] = []
    var cpus = 8
    var memMiB = 16384
    var displayWidth = 1280
    var displayHeight = 800
    var refreshRate = 60
    var dpi: Int?
    var displayMM: (Int, Int)?
    var selftestOverlay = false
    var headless = false
    var logFile: String?
    var network = true
    var sshPort = 2222
    var shmMiB = 8192
    var gpuFlags: UInt32? = nil
    var gvproxyPath: String?
    var frameDumpPath = "steamac-frame.png"
    var mouseMode: MouseMode = .absolute
    var gamepad = true
    var krunLogLevel: UInt32 = 2
    var selftestDisplay = false
    var selftestOut: String?
    var inputSelftestDelay: Double?
    var resizeSelftestDelay: Double?

    static let usage = """
    usage: steamac-vm --kernel PATH [--initrd PATH] [--cmdline STR] --disk PATH[:ro] ...
                      [--cpus N] [--mem MiB] [--display WxH] [--refresh HZ] [--headless]
                      [--log FILE] [--no-net] [--ssh-port PORT] [--shm-mib MiB]
                      [--gpu-flags HEX] [--gvproxy PATH] [--frame-dump PNG]
                      [--mouse absolute|capture] [--no-gamepad] [--krun-log-level 0-5] [--perf-stats]
           steamac-vm --selftest-display [--headless] [--selftest-out DIR] [--display WxH]
           steamac-vm --selftest-overlay [--selftest-out DIR] [--display WxH]

      --kernel PATH        raw arm64 Image (KRUN_KERNEL_FORMAT_RAW)
      --initrd PATH        initramfs
      --cmdline STR        kernel command line (default: "console=hvc0 loglevel=4 rootwait")
      --disk PATH[:ro]     raw virtio-blk disk; repeatable, order = vda, vdb, ...
      --cpus N             vCPUs (default 8)
      --mem MiB            guest RAM (default 16384)
      --display WxH        initial virtio-gpu display size (default 1280x800); afterwards the guest
                           display follows the window: content size in points = guest pixels (even,
                           min 800x500, max 4094), applied when a resize / fullscreen switch ends
      --refresh HZ         EDID refresh rate (default 60)
      --dpi N              EDID pixel density instead of the default physical size (below)
      --display-mm WxH     EDID physical size in millimetres at the initial size (overrides --dpi)
                           Default: the window's real size on the host monitor (initial content size
                           in points x the screen's mm/point), so guest UIs come out at real-world size;
                           96 dpi-equivalent when headless or the monitor reports no size. Resizes keep
                           this DPI (physical size = new size x the same mm per pixel).
      --headless           no window and no input devices; SIGUSR1 dumps the latest frame
      --log FILE           also append the hvc0 console to FILE
      --no-net             no virtio-net / gvproxy
      --ssh-port PORT      host 127.0.0.1:PORT -> guest 192.168.127.2:22 (0 disables; default 2222)
      --shm-mib MiB        virtio-gpu host-visible shared memory window (default 8192)
      --gpu-flags HEX      virglrenderer flags (default VENUS|NO_VIRGL = 0xc0)
      --gvproxy PATH       gvproxy binary (default: <exe dir>/host/bin/gvproxy, Homebrew, PATH)
      --frame-dump PNG     where SIGUSR1 writes the current frame (default ./steamac-frame.png)
      --mouse MODE         absolute (default) or capture (click grabs the pointer)
      --no-gamepad         do not create the virtual Xbox 360 pad
      --krun-log-level N   libkrun log level 0=off .. 5=trace (default 2=warn)

    Diagnostics:
      --perf-stats         every 5 s log frame pacing (also STEAMAC_PERF_STATS=1): guest flush and
                           on-screen frame intervals (p50/p95/p99/max, count > 25 / > 50 ms), libkrun's
                           per-flush copy, flush -> screen latency, dropped/replaced frames, upload time
      --selftest-display   feed synthetic frames (all formats) through the display backend vtable and
                           verify PNG dump, Metal render and (windowed) the presented drawable
      --input-selftest S   S seconds after boot, inject synthetic key/mouse/gamepad input, then
                           close the window (guest power key) 4 s later
      --selftest-overlay   drive the FX boot/shutdown overlay with synthetic console and fx.progress
                           input and write window captures at several progress points
      --resize-selftest S  S seconds after Steam is ready, resize the window 1600x1000 -> fullscreen ->
                           windowed -> 1280x800, wait for the guest's new scanout each time and dump
                           frames to <--frame-dump>-resize-N-*.png

    Window keys: Ctrl+Cmd+F fullscreen, Ctrl+Cmd+G grab pointer, Ctrl+Option release pointer.
    Closing the window (or SIGINT/SIGTERM) presses the guest power key; a second request force-quits.
    Console: hvc0 <-> this terminal (raw mode when stdin is a TTY; Ctrl+] twice force-quits).
    """

    static func parse(_ argv: [String]) throws -> Options {
        var o = Options()
        var i = 1
        func value(_ name: String) throws -> String {
            i += 1
            guard i < argv.count else { throw OptionError("\(name) needs a value") }
            return argv[i]
        }
        func int(_ name: String) throws -> Int {
            let v = try value(name)
            guard let n = Int(v) else { throw OptionError("\(name): not an integer: \(v)") }
            return n
        }
        while i < argv.count {
            let a = argv[i]
            switch a {
            case "--kernel": o.kernel = try value(a)
            case "--initrd": o.initrd = try value(a)
            case "--cmdline": o.cmdline = try value(a)
            case "--disk":
                var p = try value(a)
                var ro = false
                if p.hasSuffix(":ro") { ro = true; p.removeLast(3) }
                else if p.hasSuffix(":rw") { p.removeLast(3) }
                o.disks.append(DiskSpec(path: p, readOnly: ro))
            case "--cpus": o.cpus = try int(a)
            case "--mem": o.memMiB = try int(a)
            case "--display":
                let v = try value(a)
                let parts = v.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw OptionError("--display: expected WxH, got \(v)") }
                o.displayWidth = parts[0]; o.displayHeight = parts[1]
            case "--refresh": o.refreshRate = try int(a)
            case "--dpi":
                let d = try int(a)
                guard (50...600).contains(d) else { throw OptionError("--dpi must be 50..600") }
                o.dpi = d
            case "--display-mm":
                let v = try value(a)
                let parts = v.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, (10...5000).contains(parts[0]), (10...5000).contains(parts[1]) else {
                    throw OptionError("--display-mm: expected WxH in millimetres, got \(v)")
                }
                o.displayMM = (parts[0], parts[1])
            case "--headless": o.headless = true
            case "--log": o.logFile = try value(a)
            case "--no-net": o.network = false
            case "--ssh-port": o.sshPort = try int(a)
            case "--shm-mib": o.shmMiB = try int(a)
            case "--gpu-flags":
                let v = try value(a)
                let s = v.hasPrefix("0x") ? String(v.dropFirst(2)) : v
                guard let f = UInt32(s, radix: 16) else { throw OptionError("--gpu-flags: not hex: \(v)") }
                o.gpuFlags = f
            case "--gvproxy": o.gvproxyPath = try value(a)
            case "--frame-dump": o.frameDumpPath = try value(a)
            case "--mouse":
                let v = try value(a)
                guard let m = MouseMode(rawValue: v) else { throw OptionError("--mouse: absolute or capture") }
                o.mouseMode = m
            case "--no-gamepad": o.gamepad = false
            case "--krun-log-level": o.krunLogLevel = UInt32(clamping: try int(a))
            case "--perf-stats": break   // read by PerfStats.shared (argv is passed to the VM process)
            case "--selftest-display": o.selftestDisplay = true
            case "--selftest-out": o.selftestOut = try value(a)
            case "--selftest-overlay": o.selftestOverlay = true
            case "--resize-selftest":
                let v = try value(a)
                guard let d = Double(v), d >= 0 else { throw OptionError("--resize-selftest: seconds") }
                o.resizeSelftestDelay = d
            case "--input-selftest":
                let v = try value(a)
                guard let d = Double(v), d >= 0 else { throw OptionError("--input-selftest: seconds") }
                o.inputSelftestDelay = d
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                throw OptionError("unknown argument: \(a)")
            }
            i += 1
        }
        if !o.selftestDisplay && !o.selftestOverlay {
            guard !o.kernel.isEmpty else { throw OptionError("--kernel is required") }
            guard (1...255).contains(o.cpus) else { throw OptionError("--cpus must be 1..255") }
            guard o.memMiB >= 256 else { throw OptionError("--mem must be >= 256") }
            guard o.sshPort == 0 || (1024...65535).contains(o.sshPort) else {
                throw OptionError("--ssh-port must be 0 or 1024..65535")
            }
            for path in [o.kernel] + (o.initrd.map { [$0] } ?? []) + o.disks.map(\.path) {
                guard FileManager.default.isReadableFile(atPath: path) else {
                    throw OptionError("not readable: \(path)")
                }
            }
            if o.disks.count > 26 { throw OptionError("at most 26 disks") }
        }
        return o
    }
}

struct OptionError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
