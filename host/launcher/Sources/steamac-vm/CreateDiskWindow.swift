import AppKit
import SwiftUI

/// "Create SteamOS Disk" window (first-run sheet and Settings > Advanced "Create New Disk…"):
/// branch, home size, location and password, then DiskCreator with progress, cancel and resume
/// (a cancelled or failed run keeps the downloaded chunks; Create again continues from there).
final class CreateDiskModel: ObservableObject {
    @Published var path: String
    @Published var branch: String
    @Published var homeGiB = DiskLayout.defaultHomeGiB
    /// Shared default; users can choose a different password during creation.
    @Published var password = GuestPassword.defaultPassword
    @Published private(set) var running = false
    @Published private(set) var status: DiskCreator.Status?
    @Published private(set) var error: String?
    @Published private(set) var interrupted = false
    @Published private(set) var result: DiskCreator.Result?
    let settings: LauncherSettings
    var onFinish: ((DiskCreator.Result) -> Void)?
    private var creator: DiskCreator?

    init(settings: LauncherSettings) {
        self.settings = settings
        branch = settings.steamosBranch
        path = CreateDiskModel.freePath(settings.diskImage.isEmpty ? DiskCreator.defaultPath : settings.diskImage)
    }

    /// `steamos.img`, else `steamos-2.img`, … (an existing disk is never overwritten).
    static func freePath(_ p: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: p) else { return p }
        let base = (p as NSString).deletingPathExtension, ext = (p as NSString).pathExtension
        for i in 2... where !fm.fileExists(atPath: "\(base)-\(i).\(ext)") { return "\(base)-\(i).\(ext)" }
        return p
    }

    var storageValid: Bool { ExternalStorage.volume(forPath: path) != nil }

    var pathExists: Bool { FileManager.default.fileExists(atPath: path) }

    var freeSpace: String {
        var dir = (path as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: dir) && dir != "/" { dir = (dir as NSString).deletingLastPathComponent }
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dir),
              let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value else { return "" }
        return String(format: "%.0f GB free there; about 14 GB are needed (the disk is sparse) plus ~6 GB of download cache.",
                      Double(free) / 1e9)
    }

    func start() {
        guard !running else { return }
        settings.steamosBranch = branch
        error = nil
        interrupted = false
        running = true
        let c = DiskCreator()
        creator = c
        c.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        let request = DiskCreator.Request(path: path, branch: branch, homeGiB: homeGiB,
                                          password: password.isEmpty ? nil : password)
        log("create-disk (UI): \(request.path) branch \(request.branch) home \(request.homeGiB) GiB")
        Thread {
            let outcome: Swift.Result<DiskCreator.Result, Error>
            do { outcome = .success(try c.run(request)) } catch { outcome = .failure(error) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false
                self.creator = nil
                switch outcome {
                case .success(let r):
                    log("create-disk (UI): done: \(r.path) = SteamOS \(r.buildID)")
                    self.result = r
                    self.onFinish?(r)
                case .failure(let e as DiskCreator.Cancelled):
                    log("create-disk (UI): \(e)")
                    self.interrupted = true
                case .failure(let e):
                    log("create-disk (UI): error: \(e)")
                    CrashReporting.diskCreationFailed(e, branch: request.branch)
                    self.error = "\(e)"
                    self.interrupted = true
                }
            }
        }.start()
    }

    func cancel() { creator?.cancel() }
}

private struct CreateDiskView: View {
    @ObservedObject var model: CreateDiskModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Text("Downloads the official SteamOS image from Valve (signed bundle, ~4.5 GB of data), checks Valve's signature "
                         + "and the image checksum, and writes a new disk. The first start then finishes the setup inside the VM.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Picker("SteamOS branch", selection: $model.branch) {
                        ForEach(DiskCreator.branches, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper(value: $model.homeGiB, in: 16...2048, step: 16) {
                        HStack {
                            Text("Home partition (games, sparse)")
                            Spacer()
                            Text("\(model.homeGiB) GB").monospacedDigit()
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Location")
                            Spacer()
                            Text(model.path.isEmpty ? "Choose an external drive" : (model.path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(model.pathExists ? Color.red : Color.secondary)
                            Button("Choose SSD…") { chooseDrive() }
                            Button("Location…") { choose() }
                        }
                        Text(model.pathExists ? "A file with this name exists; it is never overwritten. Choose another name."
                             : !model.storageValid ? "Choose a mounted, writable external drive. Downloads stay on that drive." : model.freeSpace)
                            .font(.caption).foregroundStyle(model.pathExists ? Color.red : Color.secondary)
                    }
                    HStack {
                        Text("Password for user steamos (optional)")
                        Spacer()
                        SecureField("none", text: $model.password).frame(width: 160)
                    }
                }
                .disabled(model.running)
                Section {
                    CrashReportsToggle(settings: model.settings, checkbox: true)
                }
                if model.running || model.status != nil || model.error != nil {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.error != nil ? "Failed" : model.interrupted ? "Stopped — Create continues where it left off"
                                 : model.status?.title ?? "Starting…")
                                .font(.headline)
                            ProgressView(value: model.status?.fraction ?? 0)
                            Text(model.error ?? model.status?.detail ?? "")
                                .font(.caption).foregroundStyle(model.error != nil ? Color.red : Color.secondary)
                                .lineLimit(3).textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                if model.running {
                    Button("Stop") { model.cancel() }
                } else {
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                    Button(model.interrupted ? "Resume" : "Create") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.pathExists || !model.storageValid || model.result != nil)
                }
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560, height: 560)
    }

    private func chooseDrive() {
        let panel = NSOpenPanel()
        panel.title = "Choose an external SSD"
        panel.message = "Select your external drive or a folder on it. SteamOS and its download cache stay on that drive."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK, let url = panel.url {
            model.path = CreateDiskModel.freePath(url.appendingPathComponent("steamac/steamos.img").path)
        }
    }

    private func choose() {
        let panel = NSSavePanel()
        panel.title = "Location of the new SteamOS disk"
        panel.nameFieldStringValue = model.path.isEmpty ? "steamos.img" : (model.path as NSString).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: model.path.isEmpty ? "/Volumes" : (model.path as NSString).deletingLastPathComponent)
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            // NSSavePanel asked about replacing; DiskCreator never replaces: pick a free name instead.
            model.path = CreateDiskModel.freePath(url.path)
        }
    }
}

final class CreateDiskWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model: CreateDiskModel
    private var modal = false
    private static var current: CreateDiskWindowController?
    /// The non-modal window (Settings > Advanced), for --selftest-settings captures.
    static var visibleWindow: NSWindow? { current?.window }

    init(settings: LauncherSettings) {
        model = CreateDiskModel(settings: settings)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Create SteamOS Disk"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: CreateDiskView(model: model) { [weak self] in self?.window.performClose(nil) })
    }

    /// First run: blocks until the disk exists (its path) or the user closes the window (nil).
    static func runModal(settings: LauncherSettings) -> String? {
        let c = CreateDiskWindowController(settings: settings)
        c.modal = true
        c.model.onFinish = { _ in NSApp.stopModal(withCode: .OK) }
        c.window.center()
        let code = NSApp.runModal(for: c.window)
        c.window.orderOut(nil)
        return code == .OK ? c.model.result?.path : nil
    }

    /// Settings > Advanced: the new disk becomes the configured disk image (next start).
    static func show(settings: LauncherSettings) {
        if let c = current {
            c.window.makeKeyAndOrderFront(nil)
            return
        }
        let c = CreateDiskWindowController(settings: settings)
        c.model.onFinish = { r in
            settings.diskImage = r.path
            c.window.close()
        }
        current = c
        c.window.center()
        c.window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.running else { return true }
        let alert = NSAlert()
        alert.messageText = "Stop creating the disk?"
        alert.informativeText = "Downloaded data is kept; creating the disk again continues from there."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Continue")
        if alert.runModal() == .alertFirstButtonReturn { model.cancel() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if modal { NSApp.stopModal(withCode: .cancel) }
        if CreateDiskWindowController.current === self { CreateDiskWindowController.current = nil }
    }
}
