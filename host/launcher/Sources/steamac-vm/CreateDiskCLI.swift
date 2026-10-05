import Darwin
import Foundation

/// `steamac-vm --create-disk PATH`: DiskCreator without UI (same code as "Create New Disk…").
/// Progress goes to stderr; SIGINT/SIGTERM cancel (downloaded chunks stay cached for a re-run).
enum CreateDiskCLI {
    static func run(_ o: Options, settings: LauncherSettings) -> Never {
        let creator = DiskCreator()
        var request = DiskCreator.Request(path: o.createDisk!)
        request.branch = o.createBranch ?? settings.steamosBranch
        request.homeGiB = o.createHomeGiB
        if let pw = o.createPassword { request.password = pw.isEmpty ? nil : pw }
        request.keepCache = o.keepCache
        var lastLine = ""
        var lastPercent = -1
        creator.onStatus = { s in
            let pct = Int(s.fraction * 100)
            let line = "\(s.title)"
            guard line != lastLine || pct != lastPercent else { return }
            lastLine = line
            lastPercent = pct
            log("create-disk: [\(String(format: "%3d", pct))%] \(s.title)" + (s.detail.isEmpty ? "" : " · \(s.detail)"))
        }
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                log("create-disk: cancelling…")
                creator.cancel()
            }
            src.resume()
            sources.append(src)
        }
        log("create-disk: \(request.path) (branch \(request.branch), home \(request.homeGiB) GiB)")
        do {
            let r = try withExtendedLifetime(sources) { try creator.run(request) }
            log("create-disk: done: \(r.path) = SteamOS \(r.buildID) (\(r.version)); first-boot payload \(r.payload)")
            exit(0)
        } catch is DiskCreator.Cancelled {
            log("create-disk: cancelled (run the same command again to resume; cache on the selected external drive)")
            exit(130)
        } catch {
            log("create-disk: error: \(error)")
            CrashReporting.diskCreationFailed(error, branch: request.branch)
            CrashReporting.flush()
            exit(1)
        }
    }
}
