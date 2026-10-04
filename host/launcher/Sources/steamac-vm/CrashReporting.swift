import Combine
import Darwin
import Foundation
import MachO
import Metal
import Sentry

/// Crash and error reporting through Sentry (self-hosted, sentry.fxgam.es). Opt-out: Settings >
/// General "Send crash reports and diagnostics" (`sendCrashReports`, on by default, also shown by
/// the first-run alert and the Create SteamOS Disk sheet); `--no-crash-reports` or
/// `STEAMAC_SENTRY=0` turn it off for one run. Off = the SDK is never started (no network).
///
/// Both processes report: the supervisor (launcher role) and every VM process (vm role; native
/// crashes there come from Metal/MoltenVK asserts, libkrun/virglrenderer aborts and panics that
/// cross libkrun's C API). Each role has its own SDK cache, so a VM-process crash is uploaded
/// when the next VM process starts. The supervisor routes stderr through a pipe (StderrTap): every
/// line of both processes (launcher log, MoltenVK, libkrun/virglrenderer) reaches the terminal or
/// log file unchanged and also becomes a scrubbed breadcrumb, and the few error patterns worth a
/// report (guest GPU context fatal, pipeline compile failures, Rust panics) are recognised there.
/// Volume is kept low: one event per fingerprint per process, a small per-kind and total budget,
/// and a persistent "already reported" list per fingerprint.
enum CrashReporting {
    static let dsn = "https://2af7807225b4fc150d9436d1f16165b8@sentry.fxgam.es/39"
    static let disableEnv = "STEAMAC_SENTRY"
    static let debugEnv = "STEAMAC_SENTRY_DEBUG"
    static let runIdEnv = "STEAMAC_RUN_ID"
    static let noFlag = "--no-crash-reports"

    /// Settings / first-run explanation (one line) and the "What is sent" list.
    static let summary = "Crash reports and rare errors go to the FX Steam Launcher developers (Sentry). No personal data."
    static let whatIsSent = [
        "Crash reports of the launcher and the VM process: crash reason, stack traces, loaded libraries.",
        "A few errors: guest GPU context lost, shader pipeline compile failures, libkrun panics, failed disk "
            + "creation or first-start setup, VM stopped unexpectedly, SteamOS not responding.",
        "The launcher's last ~200 log lines (launcher, MoltenVK, libkrun and virglrenderer messages; home "
            + "folder paths shortened to ~) and the boot stages.",
        "Versions and setup: app, macOS, libkrun/virglrenderer/MoltenVK builds, kernel, SteamOS build, Mac "
            + "model, GPU, VM CPUs/RAM/display mode, game App IDs.",
        "A random install ID (not linked to you) to count affected Macs.",
        "Never: your name, user or computer name, IP address, Steam account, game titles, files, or the SteamOS console.",
    ]

    enum Role: String { case launcher, vm }

    enum Kind: String {
        case gpuContextFatal = "gpu-context-fatal"
        case pipelineCompile = "pipeline-compile-failed"
        case rustPanic = "rust-panic"
        case provisionFailed = "provision-failed"
        case diskCreationFailed = "disk-creation-failed"
        case vmExited = "vm-exited-unexpectedly"
        case notResponding = "steamos-not-responding"
        case test = "test-event"

        var title: String {
            switch self {
            case .gpuContextFatal: return "Guest GPU context fatal"
            case .pipelineCompile: return "Pipeline compile failed"
            case .rustPanic: return "Rust panic"
            case .provisionFailed: return "SteamOS first-start setup failed"
            case .diskCreationFailed: return "Disk creation failed"
            case .vmExited: return "VM exited unexpectedly"
            case .notResponding: return "SteamOS not responding"
            case .test: return "Sentry test event"
            }
        }

        /// The same fingerprint is reported again only after this long (persistent list).
        var quietPeriod: TimeInterval {
            switch self {
            case .pipelineCompile: return 30 * 86400   // first occurrence per shader message
            case .test: return 0
            default: return 86400
            }
        }

        /// Reports of this kind per process.
        var budget: Int {
            switch self {
            case .gpuContextFatal, .vmExited, .notResponding, .provisionFailed, .diskCreationFailed: return 2
            default: return 5
            }
        }
    }

    // MARK: state

    private static let lock = NSLock()
    nonisolated(unsafe) private static var role = Role.launcher
    nonisolated(unsafe) private static var configured = false
    nonisolated(unsafe) private(set) static var running = false
    /// Why this run is off regardless of the setting (`--no-crash-reports`, STEAMAC_SENTRY=0).
    nonisolated(unsafe) private static var runOverride: String?
    nonisolated(unsafe) private static var test = false
    nonisolated(unsafe) private static var tags: [String: String] = [:]
    nonisolated(unsafe) private static var reportedThisProcess: Set<String> = []
    nonisolated(unsafe) private static var kindCounts: [Kind: Int] = [:]
    nonisolated(unsafe) private static var settingsSubscription: AnyCancellable?
    nonisolated(unsafe) private static var tap: StderrTap?
    /// Supervisor: run dir of the current boot (VM-process tags, user-exit marker).
    nonisolated(unsafe) private static var runDir: String?
    nonisolated(unsafe) private static var lineScanner = LineScanner()

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static var releaseName: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let commit = info["SteamacGitCommit"] as? String ?? "unknown"
        return "\(LauncherSettings.defaultDomain)@\(version)+\(commit)"
    }

    private static var environment: String {
        test || !AppBundle.releaseDefaults ? "development" : "release"
    }

    private static var cacheDir: String {
        NSHomeDirectory() + "/Library/Caches/" + LauncherSettings.defaultDomain + "/sentry/" + role.rawValue
    }

    /// Random install ID shared by both processes (the SDK's own one is per cache directory):
    /// counts affected Macs, nothing else.
    private static let installID: String = {
        let path = AppBundle.appSupportDir + "/crash-reports-install-id"
        if let s = try? String(contentsOfFile: path, encoding: .utf8), UUID(uuidString: s) != nil { return s }
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(atPath: AppBundle.appSupportDir, withIntermediateDirectories: true)
        try? id.write(toFile: path, atomically: true, encoding: .utf8)
        return id
    }()

    /// The saved setting, read from the defaults store (the supervisor also sees changes the VM
    /// process's Settings window made).
    private static var settingAllows: Bool {
        LauncherSettings.shared.defaults.object(forKey: LauncherSettings.Key.sendCrashReports.rawValue) as? Bool ?? true
    }

    // MARK: setup

    /// Once per process, after the options are resolved. Self-tests never report (except the
    /// Sentry tests); `--create-disk` does.
    static func setUp(options: Options, settings: LauncherSettings) {
        let isTest = options.sentryTestEvent || options.sentryTestCrash != nil
        if options.isSelftest && options.createDisk == nil && !isTest { return }
        role = Supervisor.isChild ? .vm : .launcher
        test = isTest
        runOverride = options.noCrashReports
            ? (options.explicit.contains(noFlag) ? noFlag : "\(disableEnv)=0") : nil
        configured = true
        if let reason = runOverride {
            log("crash reporting: off for this run (\(reason))")
            return
        }
        if options.sentryTestCrash == "metal" { setenv("MTL_DEBUG_LAYER", "1", 1) }   // before Metal starts
        hostTags(options: options)
        if role == .vm {
            vmTags(options: options)
            // Settings window / first-run checkbox: apply right away in this process.
            settingsSubscription = settings.$sendCrashReports.dropFirst().removeDuplicates().sink { on in
                DispatchQueue.main.async { on ? start() : stop(reason: "turned off in Settings") }
            }
        }
        guard settings.sendCrashReports else {
            log("crash reporting: off (Settings > General)")
            return
        }
        start()
        // Supervisor: tap stderr for breadcrumbs and error patterns of both processes.
        if role == .launcher && !options.isSelftest { tap = StderrTap.install { observe(line: $0) } }
    }

    private static func start() {
        guard configured, runOverride == nil, !locked({ running }) else { return }
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        let currentTags = locked { tags }
        SentrySDK.start { o in
            o.dsn = dsn
            o.releaseName = releaseName
            o.environment = environment
            o.debug = ProcessInfo.processInfo.environment[debugEnv] == "1"
            o.cacheDirectoryPath = cacheDir
            o.sendDefaultPii = false
            o.maxBreadcrumbs = 200
            o.attachStacktrace = false
            o.enableCrashHandler = true
            o.enableUncaughtNSExceptionReporting = true
            o.enableAutoSessionTracking = false
            o.enableAppHangTracking = false
            o.enableWatchdogTerminationTracking = false
            o.enableAutoBreadcrumbTracking = false
            o.enableNetworkBreadcrumbs = false
            o.enableNetworkTracking = false
            o.enableCaptureFailedRequests = false
            o.enableSwizzling = false
            o.enableAutoPerformanceTracing = false
            o.enableFileIOTracing = false
            o.enableCoreDataTracing = false
            o.enableMetricKit = false
            o.sendClientReports = false
            o.beforeSend = { scrub(event: $0) }
            o.beforeBreadcrumb = { crumb in
                crumb.message = crumb.message.map(scrub)
                return crumb
            }
            o.initialScope = { scope in
                scope.setTags(currentTags)
                scope.setUser(User(userId: installID))
                return scope
            }
        }
        locked { running = true }
        log("crash reporting: on (\(environment), \(releaseName))")
    }

    private static func stop(reason: String) {
        guard locked({ running }) else { return }
        SentrySDK.close()
        locked { running = false }
        log("crash reporting: off (\(reason))")
    }

    /// The setting decides whether the SDK runs (supervisor, main thread only: before each boot
    /// and after the VM process ended). SentrySDK.start/close need the main thread, which waits
    /// in waitpid while a VM runs, so reports from the tap thread only check the setting.
    private static func followSetting() {
        guard configured, runOverride == nil, Thread.isMainThread else { return }
        if settingAllows { start() } else { stop(reason: "Settings > General") }
    }

    // MARK: tags

    private static func setTags(_ new: [String: String]) {
        let clean = new.filter { !$0.value.isEmpty }.mapValues { String(scrub($0).prefix(200)) }
        locked { tags.merge(clean) { $1 } }
        if locked({ running }) { SentrySDK.configureScope { $0.setTags(clean) } }
    }

    private static func hostTags(options: Options) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var t = [
            "process": role.rawValue,
            "macos": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "mac_model": sysctlString("hw.model") ?? "?",
            "host_cpus": String(ProcessInfo.processInfo.activeProcessorCount),
            "host_mem_gb": String(ProcessInfo.processInfo.physicalMemory >> 30),
            "gpu": MTLCreateSystemDefaultDevice()?.name ?? "none",
            "vm_cpus": String(options.cpus),
            "vm_mem_mib": String(options.memMiB),
        ]
        if let rev = Bundle.main.object(forInfoDictionaryKey: "SteamacMVKPatchRevision") as? String { t["mvk_patch"] = rev }
        for (tag, lib) in [("libkrun", "libkrun.1.dylib"), ("virglrenderer", "libvirglrenderer.1.dylib"),
                           ("moltenvk", "libMoltenVK.dylib")] {
            if let uuid = loadedImageUUID(suffix: "/" + lib) { t[tag] = uuid }
        }
        if let run = ProcessInfo.processInfo.environment[runIdEnv] { t["run"] = run }
        if test { t["test"] = "true" }
        locked { tags.merge(t) { $1 } }
    }

    /// VM process: boot settings, kernel version (scanned from the Image in the background).
    private static func vmTags(options: Options) {
        vmContext([
            "boot": String(Supervisor.bootNumber),
            "display_mode": options.headless ? "headless"
                : "\(options.displayWidth)x\(options.displayHeight)@\(options.refreshRate) \(options.fullscreen ? "fullscreen" : "windowed")",
            "mouse": options.mouseMode.rawValue,
            "network": options.network ? "on" : "off",
            "sound": options.sound ? "on" : "off",
        ])
        let kernel = options.kernel
        guard !kernel.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            if let k = kernelVersion(image: kernel) { vmContext(["kernel": k]) }
        }
    }

    /// VM-process tags the supervisor's reports carry too (run dir file, read at report time).
    private static func vmContext(_ new: [String: String]) {
        setTags(new)
        guard role == .vm, let dir = Supervisor.runDir else { return }
        let keys = ["boot", "display_mode", "kernel", "steamos_build", "layer", "network", "sound", "mouse"]
        let snapshot = locked { tags.filter { keys.contains($0.key) } }
        if let data = try? JSONSerialization.data(withJSONObject: snapshot) {
            try? data.write(to: URL(fileURLWithPath: dir + "/sentry-tags.json"), options: .atomic)
        }
    }

    /// hvc0 lines of interest (the console itself is never reported): the initramfs names the
    /// SteamOS build it boots and the steamac layer release.
    static func consoleLine(_ raw: String) {
        guard configured, raw.contains("steamac-init: ") else { return }
        if let r = raw.range(of: "steamac-init: rootfs-"), let b = raw.range(of: "BUILD_ID=", range: r.upperBound..<raw.endIndex) {
            let id = raw[b.upperBound...].prefix { !$0.isWhitespace }
            if !id.isEmpty { vmContext(["steamos_build": String(id)]) }
        } else if let r = raw.range(of: "steamac-init: steamac layer "), let c = raw.range(of: ": ", range: r.upperBound..<raw.endIndex) {
            let release = raw[c.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !release.isEmpty { vmContext(["layer": release]) }
        }
    }

    // MARK: supervisor hooks

    /// Before each boot: follow the setting, remember the run dir, give the VM process the run id.
    static func supervisorBoot(_ o: Options, boot: Int, runDir dir: String, env: inout [String: String]) {
        guard configured, role == .launcher else { return }
        runDir = dir
        try? FileManager.default.removeItem(atPath: dir + "/user-exit")
        try? FileManager.default.removeItem(atPath: dir + "/sentry-tags.json")
        let run = locked { tags["run"] } ?? String(format: "%08x", arc4random())
        env[runIdEnv] = run
        setTags(["run": run, "boot": String(boot), "vm_cpus": String(o.cpus), "vm_mem_mib": String(o.memMiB)])
        followSetting()
    }

    /// VM process: the user asked the VM to stop (window close, menu, signal, restart).
    static func noteUserExit() {
        guard let dir = Supervisor.runDir else { return }
        FileManager.default.createFile(atPath: dir + "/user-exit", contents: nil)
    }

    /// Supervisor: the VM process ended. Reports non-zero exits the user did not ask for and
    /// every crash (signal); flushes before the supervisor exits.
    static func vmExited(status: Int32) {
        guard configured, role == .launcher, status != 0, let dir = runDir else { return }
        let userExit = FileManager.default.fileExists(atPath: dir + "/user-exit")
        let signal = status > 128 ? status - 128 : 0
        if signal == 0 && userExit { return }
        if userExit && [SIGKILL, SIGTERM, SIGINT, SIGHUP].contains(signal) { return }
        followSetting()
        tap?.waitIdle()   // the VM process's last lines are breadcrumbs of this report
        let (pending, last) = locked { (lineScanner.flushPending(), lineScanner.lastError) }
        for (kind, key, message) in pending { report(kind, key: key, message: message) }
        let what = signal != 0 ? "VM process crashed (\(signalName(signal)))" : "VM process exited with status \(status)"
        let lastError = last.map { ": \($0)" } ?? ""
        report(.vmExited, key: signal != 0 ? signalName(signal) : "status \(status)", message: what + lastError,
               tags: ["exit_status": String(status), "signal": signal != 0 ? signalName(signal) : "none",
                      "user_exit": userExit ? "yes" : "no"])
        flush()
    }

    /// Before a deliberate exit right after a report.
    static func flush(timeout: TimeInterval = 5) {
        if locked({ running }) { SentrySDK.flush(timeout: timeout) }
    }

    /// Supervisor exit: the pipe's remaining lines go out before the process ends.
    static func finish() {
        tap?.drain(timeout: 2)
    }

    // MARK: VM-process hooks

    static func stallNotResponding(seconds: TimeInterval) {
        report(.notResponding, key: "not-responding", message: "SteamOS not responding (no GPU work for \(Int(seconds)) s)",
               tags: ["stall_seconds": String(Int(seconds))])
    }

    static func provisionFailed(reason: String) {
        report(.provisionFailed, key: normalize(reason), message: "Provisioning failed: \(reason.isEmpty ? "(no reason given)" : reason)")
    }

    static func diskCreationFailed(_ error: Error, branch: String) {
        let text = "\(error)"
        report(.diskCreationFailed, key: normalize(text), message: "Disk creation failed: \(text)", tags: ["steamos_branch": branch])
    }

    // MARK: log lines

    /// Every `log()` line of this process. In the supervisor the tap sees them (and the VM
    /// process's lines and stderr of the libraries) instead.
    static func logged(_ message: String) {
        guard locked({ running && tap == nil }) else { return }
        SentrySDK.addBreadcrumb(breadcrumb(for: "[steamac-vm] " + message))
    }

    private static func breadcrumb(for line: String) -> Breadcrumb {
        var level = SentryLevel.info
        var category = "stderr"
        if line.hasPrefix("[steamac-vm] ") {
            category = line.hasPrefix("[steamac-vm] progress: ") ? "boot" : "launcher"
            if line.contains("error") || line.contains("fail") { level = .warning }
        } else if line.hasPrefix("[mvk-") {
            category = "moltenvk"
            level = line.hasPrefix("[mvk-error]") ? .error : .warning
        } else if line.contains("virglrenderer") || line.contains("vkr:") {
            category = "virglrenderer"
            level = .warning
        } else if line.contains(" krun") || line.contains("WARN ") || line.contains("ERROR ") {
            category = "libkrun"
            level = line.contains("ERROR ") ? .error : .warning
        }
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = String(scrub(line).prefix(600))
        return crumb
    }

    /// Supervisor tap: one stderr line of either process.
    private static func observe(line: String) {
        guard locked({ running }) else { return }
        SentrySDK.addBreadcrumb(breadcrumb(for: line))
        for (kind, key, message) in locked({ lineScanner.feed(line) }) {
            report(kind, key: key, message: message)
        }
    }

    // MARK: reports

    /// Rate-limited, deduplicated report (no-op when reporting is off).
    static func report(_ kind: Kind, key: String, message: String, tags extra: [String: String] = [:]) {
        guard configured else { return }
        guard locked({ running }) else { return }
        // Supervisor: the VM process's Settings window may have turned reporting off meanwhile.
        if role == .launcher { guard settingAllows else { return } }
        let fingerprint = kind.rawValue + "|" + key
        let allowed: Bool = locked {
            guard !reportedThisProcess.contains(fingerprint), kindCounts[kind, default: 0] < kind.budget,
                  reportedThisProcess.count < 12 else { return false }
            reportedThisProcess.insert(fingerprint)
            kindCounts[kind, default: 0] += 1
            return true
        }
        guard allowed, test || ReportedStore.claim(fingerprint, quietPeriod: kind.quietPeriod) else { return }
        let event = Event(level: kind == .test ? .info : .error)
        event.message = SentryMessage(formatted: String(scrub(message).prefix(2000)))
        event.fingerprint = [kind.rawValue, String(key.prefix(200))]
        var t = extra
        t["kind"] = kind.rawValue
        if role == .launcher, let dir = runDir,
           let data = FileManager.default.contents(atPath: dir + "/sentry-tags.json"),
           let vm = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
            t.merge(vm) { old, _ in old }
        }
        let scoped = t.mapValues { String(scrub($0).prefix(200)) }
        SentrySDK.capture(event: event) { scope in scope.setTags(scoped) }
        log("crash reporting: sent \(kind.rawValue) report")
    }

    // MARK: test flags

    /// `--sentry-test-event`: a test event from this process (VM process: then exit, after the
    /// SDK sent it and any crash report left by an earlier VM process). `--sentry-test-crash
    /// MODE`: the VM process crashes right away (abort | segv | metal), or (panic) boots with a
    /// kernel command line longer than libkrun's 2048-byte limit: `Cmdline::insert_str().unwrap()`
    /// panics inside krun_start_enter, and a panic cannot unwind out of the extern "C" function,
    /// so Rust aborts the process.
    static func runTests(_ options: inout Options) {
        guard configured, options.sentryTestEvent || options.sentryTestCrash != nil else { return }
        if options.sentryTestEvent {
            guard locked({ running }) else {
                log("sentry test: crash reporting is off; nothing sent")
                if role == .vm { exit(0) }
                return
            }
            report(.test, key: role.rawValue, message: "Sentry test event (\(role.rawValue) process)")
            if role == .vm {
                // Crash reports of earlier VM processes are converted and queued after start.
                Thread.sleep(forTimeInterval: 3)
                SentrySDK.flush(timeout: 15)
                log("sentry test: flushed; exiting")
                exit(0)
            }
            SentrySDK.flush(timeout: 15)
        }
        guard role == .vm, let mode = options.sentryTestCrash else { return }
        if mode == "panic" {
            log("sentry test: booting with a 2100-byte kernel command line (libkrun panics in krun_start_enter)")
            options.cmdline += " steamac.sentrytest=" + String(repeating: "x", count: 2100)
            return
        }
        log("sentry test: crashing the VM process (\(mode))")
        Thread.sleep(forTimeInterval: 0.5)   // the log line reaches the supervisor's tap
        TestCrash.run(mode)
    }

    // MARK: scrubbing

    private static let homeRegex = try! NSRegularExpression(pattern: "/Users/[^/\\s\"':,;)]+")
    private static let emailRegex = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    private static let ipv4Regex = try! NSRegularExpression(pattern: "(?<![\\w.~-])(?:\\d{1,3}\\.){3}\\d{1,3}(?![\\w.~-])")
    /// Names that identify the user or the Mac (whole words, 4+ characters).
    private static let identityRegexes: [NSRegularExpression] = {
        var names = [NSUserName(), NSFullUserName(), ProcessInfo.processInfo.hostName]
        if let local = Host.current().localizedName { names.append(local) }
        names += names.map { $0.replacingOccurrences(of: ".local", with: "") }
        return Set(names.filter { $0.count >= 4 }).compactMap {
            try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b", options: .caseInsensitive)
        }
    }()

    static func scrub(_ s: String) -> String {
        var out = s
        func replace(_ re: NSRegularExpression, _ with: (String) -> String) {
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return }
            let result = NSMutableString(string: out)
            for m in matches.reversed() { result.replaceCharacters(in: m.range, with: with(ns.substring(with: m.range))) }
            out = result as String
        }
        if out.contains("/Users/") { replace(homeRegex) { _ in "~" } }
        if out.contains("@") { replace(emailRegex) { m in m.hasPrefix(LauncherSettings.defaultDomain) ? m : "<email>" } }
        replace(ipv4Regex) { ip in ip.hasPrefix("127.") || ip.hasPrefix("192.168.127.") || ip == "0.0.0.0" ? ip : "<ip>" }
        for re in identityRegexes { replace(re) { _ in "<redacted>" } }
        return out
    }

    private static func scrubAny(_ v: Any) -> Any {
        switch v {
        case let s as String: return scrub(s)
        case let d as [String: Any]: return d.mapValues(scrubAny)
        case let a as [Any]: return a.map(scrubAny)
        default: return v
        }
    }

    private static func scrub(frames: SentryStacktrace?) {
        for f in frames?.frames ?? [] {
            f.package = f.package.map(scrub)
            f.fileName = f.fileName.map(scrub)
        }
    }

    /// Last line of defence for every event (crash reports from earlier runs included).
    static func scrub(event e: Event) -> Event {
        e.serverName = nil
        if let m = e.message { e.message = SentryMessage(formatted: scrub(m.formatted)) }
        if let u = e.user {
            u.ipAddress = nil
            u.username = nil
            u.email = nil
            u.name = nil
        }
        for x in e.exceptions ?? [] {
            x.value = x.value.map(scrub)
            scrub(frames: x.stacktrace)
        }
        for t in e.threads ?? [] {
            t.name = t.name.map(scrub)
            scrub(frames: t.stacktrace)
        }
        scrub(frames: e.stacktrace)
        for d in e.debugMeta ?? [] { d.codeFile = d.codeFile.map(scrub) }
        for b in e.breadcrumbs ?? [] { b.message = b.message.map(scrub) }
        e.context = e.context.map { $0.mapValues { $0.mapValues(scrubAny) } }
        if var device = e.context?["device"] { device.removeValue(forKey: "name"); e.context?["device"] = device }
        e.context?.removeValue(forKey: "culture")   // locale and time zone
        e.extra = e.extra.map { $0.mapValues(scrubAny) }
        e.tags = e.tags.map { $0.mapValues(scrub) }
        return e
    }

    /// Normalised fingerprint text: digits and hex addresses removed, length capped.
    static func normalize(_ s: String) -> String {
        var out = ""
        var lastWasDigit = false
        for ch in scrub(s) {
            if ch.isNumber {
                if !lastWasDigit { out.append("#") }
                lastWasDigit = true
            } else {
                lastWasDigit = false
                out.append(ch)
            }
        }
        return String(out.replacingOccurrences(of: "0x#", with: "#").prefix(300))
    }

    // MARK: helpers

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// LC_UUID of a loaded image (matches its dSYM / the debug files dist.sh uploads).
    static func loadedImageUUID(suffix: String) -> String? {
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i), String(cString: name).hasSuffix(suffix),
                  let header = _dyld_get_image_header(i) else { continue }
            var p = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let cmd = p.load(as: load_command.self)
                if cmd.cmd == LC_UUID {
                    let u = p.load(as: uuid_command.self).uuid
                    return UUID(uuid: u).uuidString.lowercased()
                }
                p = p.advanced(by: Int(cmd.cmdsize))
            }
        }
        return nil
    }

    /// "7.2.9-steamac #1 SMP PREEMPT Sun Oct 4 11:27:59 UTC 2026" from a raw arm64 Image.
    static func kernelVersion(image path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        let needle = Data("Linux version ".utf8)
        var from = data.startIndex
        while let r = data.range(of: needle, in: from..<data.endIndex) {
            let end = data[r.upperBound...].prefix(400).firstIndex { $0 == 0 || $0 == 10 } ?? min(data.endIndex, r.upperBound + 400)
            let text = String(decoding: data[r.upperBound..<end], as: UTF8.self)
            if let hash = text.range(of: " #"), text[hash.upperBound...].first?.isNumber == true {
                let release = text.prefix { $0 != " " }
                return (release + text[hash.lowerBound...]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            from = r.upperBound
        }
        return nil
    }

    private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGFPE: return "SIGFPE"
        case SIGKILL: return "SIGKILL"
        case SIGTERM: return "SIGTERM"
        case SIGINT: return "SIGINT"
        case SIGHUP: return "SIGHUP"
        case SIGPIPE: return "SIGPIPE"
        case SIGSYS: return "SIGSYS"
        default: return "signal \(sig)"
        }
    }
}

/// Error patterns in the supervisor's stderr stream (both processes). Multi-line messages
/// (MoltenVK compile errors, Rust panics) collect their continuation lines first.
private struct LineScanner {
    private var pending: (kind: CrashReporting.Kind, header: String, lines: [String])?
    /// Last launcher error line (`[steamac-vm] error: …`), for VM exit reports.
    private(set) var lastError: String?

    mutating func feed(_ line: String) -> [(CrashReporting.Kind, String, String)] {
        var out: [(CrashReporting.Kind, String, String)] = []
        if var p = pending {
            let continuation = !line.hasPrefix("[") && !line.hasPrefix("thread '") && p.lines.count < 6
            if continuation && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                p.lines.append(line)
                pending = p
                if p.kind == .rustPanic && p.lines.count >= 1 { out.append(finish()) }
                return out
            }
            out.append(finish())
        }
        if line.hasPrefix("[steamac-vm] error: ") || line.hasPrefix("[steamac-vm] provision failed") {
            lastError = String(line.dropFirst("[steamac-vm] ".count).prefix(300))
        } else if line.contains("failed assertion") || line.contains("panicked at") || line.hasPrefix("Fatal error: ") {
            lastError = String(line.prefix(300))
        }
        if line.contains("fatal decoder state") || line.contains("vn_dispatch_command failed")
            || line.contains("hit device lost") || line.contains("CS error") || line.contains("Lost VkDevice")
            || line.contains("VK_ERROR_DEVICE_LOST") {
            out.append((.gpuContextFatal, "boot \(ProcessInfo.processInfo.environment[Supervisor.bootEnv] ?? "")",
                        "Guest GPU context fatal: \(line)"))
        } else if line.hasPrefix("[mvk-error]") && line.contains("compile failed") {
            pending = (.pipelineCompile, line, [])
        } else if line.contains("creation failed on host") && line.contains("pipeline") {
            out.append((.pipelineCompile, CrashReporting.normalize(line), "Pipeline creation failed on host: \(line)"))
        } else if line.hasPrefix("thread '") && line.contains("panicked at") {
            pending = (.rustPanic, line, [])
        }
        return out
    }

    /// A multi-line message still collecting continuation lines (the VM process ended).
    mutating func flushPending() -> [(CrashReporting.Kind, String, String)] {
        pending == nil ? [] : [finish()]
    }

    private mutating func finish() -> (CrashReporting.Kind, String, String) {
        let p = pending!
        pending = nil
        let detail = p.lines.joined(separator: "\n")
        switch p.kind {
        case .rustPanic:
            // thread 'name' panicked at src/x.rs:12:5:\n<message>
            let at = p.header.range(of: "panicked at ").map { String(p.header[$0.upperBound...]) } ?? p.header
            return (.rustPanic, CrashReporting.normalize(at), "Rust panic at \(at) \(detail)")
        default:
            return (p.kind, CrashReporting.normalize(p.header + "\n" + detail), "\(p.header)\n\(detail)")
        }
    }
}

/// Fingerprints reported recently, shared by both processes
/// (~/Library/Caches/es.fxgam.steamac/sentry/reported.json).
private enum ReportedStore {
    private static let lock = NSLock()
    private static var path: String {
        NSHomeDirectory() + "/Library/Caches/" + LauncherSettings.defaultDomain + "/sentry/reported.json"
    }

    /// True (and recorded) unless the fingerprint was reported within `quietPeriod`.
    static func claim(_ fingerprint: String, quietPeriod: TimeInterval) -> Bool {
        guard quietPeriod > 0 else { return true }
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        var seen = (FileManager.default.contents(atPath: path)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Double]) ?? [:]
        if let last = seen[fingerprint], now - last < quietPeriod { return false }
        seen = seen.filter { now - $0.value < 60 * 86400 }
        if seen.count > 2000 { seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(1500).map { ($0.key, $0.value) }) }
        seen[fingerprint] = now
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: seen) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        return true
    }
}

/// Supervisor stderr: fd 2 becomes a pipe; a reader thread copies everything to the original
/// stderr (terminal or log file) and hands complete lines to `onLine`. The VM process inherits
/// the pipe, so its output survives its crash (bytes already written stay in the pipe).
final class StderrTap {
    private let original: Int32
    private let readFD: Int32
    private let onLine: (String) -> Void
    private let done = DispatchSemaphore(value: 0)
    private let idle = NSCondition()
    private var busy = false
    /// FIONREAD = _IOR('f', 127, int) (the macro is not imported into Swift).
    private static let fionread: UInt = 0x4004_667f

    private init(original: Int32, readFD: Int32, onLine: @escaping (String) -> Void) {
        self.original = original
        self.readFD = readFD
        self.onLine = onLine
    }

    static func install(onLine: @escaping (String) -> Void) -> StderrTap? {
        var fds: [Int32] = [0, 0]
        let original = dup(STDERR_FILENO)
        guard original >= 0, pipe(&fds) == 0 else { return nil }
        _ = fcntl(original, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        let tap = StderrTap(original: original, readFD: fds[0], onLine: onLine)
        guard dup2(fds[1], STDERR_FILENO) >= 0 else { return nil }
        close(fds[1])
        let t = Thread { tap.run() }
        t.name = "steamac.stderr-tap"
        t.qualityOfService = .utility
        t.start()
        atexit { CrashReporting.finish() }
        return tap
    }

    private func run() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var partial = [UInt8]()
        while true {
            let n = buf.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            idle.lock(); busy = true; idle.unlock()
            buf.withUnsafeBytes { p in
                var off = 0
                while off < n {
                    let w = write(original, p.baseAddress! + off, n - off)
                    if w < 0 && errno == EINTR { continue }
                    if w <= 0 { break }
                    off += w
                }
            }
            partial.append(contentsOf: buf[0..<n])
            while let nl = partial.firstIndex(of: 10) {
                let line = String(decoding: partial[..<nl].prefix(2000), as: UTF8.self)
                partial.removeSubrange(...nl)
                onLine(line)
            }
            if partial.count > 8192 { partial.removeAll() }
            var avail: Int32 = 0
            if ioctl(readFD, StderrTap.fionread, &avail) == 0 && avail == 0 {
                idle.lock(); busy = false; idle.broadcast(); idle.unlock()
            }
        }
        idle.lock(); busy = false; idle.broadcast(); idle.unlock()
        done.signal()
    }

    /// Until everything written so far was processed (or 1 s).
    func waitIdle() {
        idle.lock()
        defer { idle.unlock() }
        var avail: Int32 = 0
        let deadline = Date().addingTimeInterval(1)
        while busy || (ioctl(readFD, StderrTap.fionread, &avail) == 0 && avail > 0) {
            if !idle.wait(until: deadline) { break }
        }
    }

    /// Restore fd 2 and let the reader finish the pipe (other holders of the write end, e.g. a
    /// helper still running, cap the wait at `timeout`).
    func drain(timeout: TimeInterval) {
        guard dup2(original, STDERR_FILENO) >= 0 else { return }
        _ = done.wait(timeout: .now() + timeout)
    }
}

/// `--sentry-test-crash MODE` (VM process): crash inside C / Metal / libkrun code.
private enum TestCrash {
    static func run(_ mode: String) -> Never {
        switch mode {
        case "segv":
            // EXC_BAD_ACCESS inside libsystem's memset.
            memset(UnsafeMutableRawPointer(bitPattern: 16), 0, 64)
        case "metal":
            // Metal API assertion (MTL_DEBUG_LAYER set before the device was created): an encoder
            // released without endEncoding.
            if let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let cb = q.makeCommandBuffer() {
                _ = cb.makeComputeCommandEncoder()
                cb.commit()
            }
        default:
            // abort() from a callback inside a C library call (qsort).
            var values: [Int32] = [3, 1, 2]
            qsort(&values, values.count, MemoryLayout<Int32>.size) { _, _ in abort() }
        }
        abort()
    }
}
