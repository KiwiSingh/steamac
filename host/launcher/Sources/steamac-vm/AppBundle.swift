import AppKit
import Darwin
import Foundation

/// Running inside "FX Steam Launcher.app" (build.sh / bundle.sh): the kernel, initramfs, layer
/// disk and gvproxy are bundled in Contents/Resources; the SteamOS disk comes from Settings >
/// Advanced "Disk image", else the default locations below. Never copied anywhere: the user
/// picks an existing image.
enum AppBundle {
    /// Contents/Resources when this executable lives in an .app bundle.
    static var resources: String? {
        Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.resourcePath : nil
    }

    static var appSupportDir: String {
        NSHomeDirectory() + "/Library/Application Support/" + LauncherSettings.defaultDomain
    }

    static var logPath: String {
        NSHomeDirectory() + "/Library/Logs/" + LauncherSettings.defaultDomain + "/steamac-vm.log"
    }

    /// Where a disk is looked for when Settings has none: Application Support, then the repo's
    /// work/out (next to the bundle, or the build tree recorded in Info.plist at bundle time).
    static func defaultDiskCandidates() -> [String] {
        var c = [appSupportDir + "/steamos.img"]
        let sibling = (Bundle.main.bundlePath as NSString).deletingLastPathComponent + "/steamos.img"
        if resources != nil { c.append(sibling) }
        if let out = Bundle.main.object(forInfoDictionaryKey: "SteamacBuildOut") as? String {
            let p = out + "/steamos.img"
            if !c.contains(p) { c.append(p) }
        }
        return c
    }

    static func defaultDisk() -> String? {
        defaultDiskCandidates().first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// The disk the next start uses (Settings value or default), nil if none is usable.
    static func configuredDisk(_ settings: LauncherSettings) -> String? {
        if !settings.diskImage.isEmpty {
            return FileManager.default.isReadableFile(atPath: settings.diskImage) ? settings.diskImage : nil
        }
        return defaultDisk()
    }

    /// Bundle defaults for what the command line did not give.
    static func fill(_ o: inout Options, settings: LauncherSettings, overrides: inout [LauncherSettings.Key: String]) {
        guard let res = resources else { return }
        if o.kernel.isEmpty { o.kernel = res + "/Image" }
        if o.initrd == nil && !o.explicit.contains("--kernel") { o.initrd = res + "/initramfs.cpio.gz" }
        if o.gvproxyPath == nil, FileManager.default.isExecutableFile(atPath: res + "/gvproxy") {
            o.gvproxyPath = res + "/gvproxy"
        }
        // SIGUSR1 frame dumps: the app's working directory is / (not writable).
        if !o.explicit.contains("--frame-dump") {
            let dir = (logPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            o.frameDumpPath = dir + "/steamac-frame.png"
        }
        guard o.disks.isEmpty else { return }
        guard let disk = configuredDisk(settings) else {
            o.needsDisk = true
            return
        }
        o.disks = [DiskSpec(path: disk, readOnly: false), DiskSpec(path: res + "/steamac-layer.img", readOnly: true)]
    }

    /// Finder / `open` launch: stdout and stderr are /dev/null, so the guest console and the
    /// launcher log are appended to ~/Library/Logs/es.fxgam.steamac/steamac-vm.log instead
    /// (rotated at 64 MiB). Running Contents/MacOS/steamac-vm from a shell keeps the terminal/pipes.
    static var outputDiscarded: Bool {
        var null = stat(), out = stat(), err = stat()
        guard stat("/dev/null", &null) == 0, fstat(STDOUT_FILENO, &out) == 0, fstat(STDERR_FILENO, &err) == 0 else { return false }
        return (out.st_rdev, err.st_rdev) == (null.st_rdev, null.st_rdev)
            && (out.st_mode & S_IFMT) == S_IFCHR && (err.st_mode & S_IFMT) == S_IFCHR
    }

    static func redirectOutputIfLaunchedFromFinder() {
        guard resources != nil, outputDiscarded else { return }
        let path = logPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        var st = stat()
        if stat(path, &st) == 0, st.st_size > 64 << 20 {
            rename(path, (path as NSString).deletingPathExtension + ".old.log")
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        close(fd)
        let stamp = ISO8601DateFormatter().string(from: Date())
        log("---- \(stamp) FX Steam Launcher started (pid \(getpid()), \(Bundle.main.bundlePath))")
    }
}

/// First start of the app without a usable disk image: explain, let the user pick an existing
/// image (Settings > Advanced "Disk image"), then the supervisor boots it.
enum FirstRun {
    static func run(settings: LauncherSettings) -> Never {
        let app = NSApplication.shared
        log("first run: no usable disk image (\(settings.diskImage.isEmpty ? "none found" : settings.diskImage)); asking the user")
        app.setActivationPolicy(.regular)
        MainMenu.installMinimal()
        app.activate()
        let alert = NSAlert()
        alert.messageText = "No SteamOS disk image"
        let looked = AppBundle.defaultDiskCandidates().map { "• " + ($0 as NSString).abbreviatingWithTildeInPath }
        var info = "FX Steam Launcher needs a SteamOS disk image (steamos.img, ~87 GB sparse).\n\n"
        if !settings.diskImage.isEmpty {
            info += "The image chosen in Settings is not readable:\n\((settings.diskImage as NSString).abbreviatingWithTildeInPath)\n\n"
        }
        info += "Looked in:\n\(looked.joined(separator: "\n"))\n\n"
        info += "Build one from the repository with scripts/build-image.sh (see README), or choose an existing image. "
        info += "The image is used in place; it is never copied."
        alert.informativeText = info
        alert.addButton(withTitle: "Use Existing Disk…")
        alert.addButton(withTitle: "Quit")
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else {
                log("first run: no disk chosen; quitting")
                exit(0)
            }
            let panel = NSOpenPanel()
            panel.title = "Choose a SteamOS disk image"
            panel.message = "Raw GPT disk image (e.g. steamos.img). It stays where it is."
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.treatsFilePackagesAsDirectories = false
            guard panel.runModal() == .OK, let url = panel.url else { continue }
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            settings.diskImage = url.path
            log("first run: disk image \(url.path)")
            // Tell the supervisor to start the VM now (same marker as a guest reboot).
            if let dir = Supervisor.runDir {
                FileManager.default.createFile(atPath: Supervisor.rebootMarker(dir), contents: Data(Supervisor.firstRunMarker.utf8))
            }
            exit(0)
        }
    }
}
