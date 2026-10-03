import AppKit
import Foundation
import QuartzCore
import os

/// `--perf-stats` / STEAMAC_PERF_STATS=1: every 5 s, log how guest frames travel to the screen.
///
///   flush   guest flushes of scanout 0 (libkrun present_frame, GPU worker thread): interval
///           distribution and libkrun's per-flush copy into our frame (alloc_frame -> present_frame)
///   shown   new frames on screen: each drawable is shown at the first display refresh after its
///           command buffer completed (displaySyncEnabled), and never at the same refresh as the
///           previous one. The refresh grid comes from the view's CADisplayLink: macOS 15 reports
///           MTLDrawable.presentedTime 0 for nearly every drawable, so it cannot be used.
///           Interval distribution, refreshes per frame (`vsyncs 2:1194 3:4` = 1194 frames held for
///           2 refreshes, 4 for 3), flush -> screen latency, flushes replaced in the mailbox before
///           the main thread took them, main-thread upload and nextDrawable waits.
///
/// Intervals over 25 ms (more than 1.5 frames at 60 Hz) and 50 ms are the visible stutters.
final class PerfStats {
    static let shared: PerfStats? = {
        let env = ProcessInfo.processInfo.environment["STEAMAC_PERF_STATS"]
        return (env == "1" || CommandLine.arguments.contains("--perf-stats")) ? PerfStats() : nil
    }()

    static let period: TimeInterval = 5

    private var lock = os_unfair_lock()
    private var flushTimes: [CFTimeInterval] = []
    private var copyMs: [Double] = []
    private var allocAt: CFTimeInterval = 0
    private var lastFlushAt: CFTimeInterval = 0
    private var shownTimes: [CFTimeInterval] = []
    private var refreshesPerFrame: [Int: Int] = [:]
    private var latencyMs: [Double] = []
    private var uploadMs: [Double] = []
    private var drawableWaitMs: [Double] = []
    private var taken = 0
    private var lastFlush: CFTimeInterval = 0
    private var lastShown: CFTimeInterval = 0
    private var vsyncBase: CFTimeInterval = 0
    private var vsyncPeriod: CFTimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var displayLink: CADisplayLink?
    private let linkTarget = LinkTarget()

    private init() { linkTarget.stats = self }

    private func locked(_ body: () -> Void) {
        os_unfair_lock_lock(&lock)
        body()
        os_unfair_lock_unlock(&lock)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + PerfStats.period, repeating: PerfStats.period)
        t.setEventHandler { [weak self] in self?.report() }
        t.resume()
        timer = t
        log("perf: stats every \(Int(PerfStats.period)) s (intervals in ms; >25/>50 = intervals longer than that)")
    }

    /// Main thread: follow the refreshes of the display showing `view`.
    func attach(view: NSView) {
        displayLink?.invalidate()
        let link = view.displayLink(target: linkTarget, selector: #selector(LinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private final class LinkTarget: NSObject {
        weak var stats: PerfStats?
        @objc func tick(_ link: CADisplayLink) {
            guard let stats, link.duration > 0 else { return }
            let (t, d) = (link.timestamp, link.duration)
            stats.locked { stats.vsyncBase = t; stats.vsyncPeriod = d }
        }
    }

    // GPU worker thread (libkrun display callbacks).
    func frameAllocated() {
        let now = CACurrentMediaTime()
        locked { allocAt = now }
    }

    func framePresented() {
        let now = CACurrentMediaTime()
        locked {
            flushTimes.append(now)
            if allocAt > 0 { copyMs.append((now - allocAt) * 1000) }
            allocAt = 0
            lastFlushAt = now
        }
    }

    // Main thread.
    /// The flush time of the frame the presenter just took (the latest flush).
    func frameTaken() -> CFTimeInterval {
        var t: CFTimeInterval = 0
        locked { taken += 1; t = lastFlushAt }
        return t
    }

    func uploaded(ms: Double) { locked { uploadMs.append(ms) } }
    func waitedForDrawable(ms: Double) { locked { drawableWaitMs.append(ms) } }

    // Metal completion thread: the drawable's command buffer completed.
    func rendered(flushedAt: CFTimeInterval) {
        let now = CACurrentMediaTime()
        locked {
            var shown = now
            if vsyncPeriod > 0 {
                shown = vsyncBase + (((now - vsyncBase) / vsyncPeriod).rounded(.up)) * vsyncPeriod
                let prev = shownTimes.last ?? lastShown
                if prev > 0 {
                    // One new drawable per refresh at most: a second one waits for the next.
                    if shown < prev + vsyncPeriod / 2 { shown = prev + vsyncPeriod }
                    let refreshes = Int(((shown - prev) / vsyncPeriod).rounded())
                    refreshesPerFrame[refreshes, default: 0] += 1
                }
            }
            shownTimes.append(shown)
            if flushedAt > 0 { latencyMs.append((shown - flushedAt) * 1000) }
        }
    }

    private func report() {
        var flushes: [CFTimeInterval] = [], shown: [CFTimeInterval] = []
        var copy: [Double] = [], lat: [Double] = [], up: [Double] = [], wait: [Double] = []
        var hist: [Int: Int] = [:]
        var took = 0, prevFlush: CFTimeInterval = 0, prevShown: CFTimeInterval = 0, refresh: CFTimeInterval = 0
        locked {
            swap(&flushes, &flushTimes); swap(&shown, &shownTimes)
            swap(&copy, &copyMs); swap(&lat, &latencyMs); swap(&up, &uploadMs); swap(&wait, &drawableWaitMs)
            swap(&hist, &refreshesPerFrame)
            took = taken; taken = 0
            prevFlush = lastFlush; prevShown = lastShown
            if let l = flushes.last { lastFlush = l }
            if let l = shown.last { lastShown = l }
            refresh = vsyncPeriod
        }
        // Intervals continue across reports (the first one starts at the previous report's last frame).
        func intervals(_ ts: [CFTimeInterval], from prev: CFTimeInterval) -> [Double] {
            var out: [Double] = []
            var p = prev
            for t in ts {
                if p > 0 { out.append((t - p) * 1000) }
                p = t
            }
            return out
        }
        let fi = intervals(flushes, from: prevFlush), si = intervals(shown, from: prevShown)
        let vsyncs = hist.keys.sorted().map { "\($0):\(hist[$0]!)" }.joined(separator: " ")
        var line = "perf: flush n=\(flushes.count) \(PerfStats.dist(fi))"
        line += " copy avg/max=\(PerfStats.avgMax(copy))"
        line += " | shown n=\(shown.count) \(PerfStats.dist(si))"
        line += " vsyncs(\(refresh > 0 ? String(format: "%.0f Hz", 1 / refresh) : "?")) \(vsyncs.isEmpty ? "-" : vsyncs)"
        line += " lat p50/p99=\(PerfStats.f(PerfStats.pct(lat, 50)))/\(PerfStats.f(PerfStats.pct(lat, 99)))"
        line += " replaced=\(max(0, flushes.count - took))"
        line += " upload avg/max=\(PerfStats.avgMax(up)) drawable-wait max=\(PerfStats.f(wait.max() ?? 0))"
        log(line)
    }

    private static func f(_ v: Double) -> String { String(format: "%.1f", v) }

    private static func pct(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p / 100).rounded()))]
    }

    private static func dist(_ v: [Double]) -> String {
        // +0.5 ms: shown intervals are whole refreshes (3 x 8.33 ms must count as > 25).
        let over25 = v.filter { $0 > 24.5 }.count, over50 = v.filter { $0 > 49.5 }.count
        return "p50/p95/p99/max=\(f(pct(v, 50)))/\(f(pct(v, 95)))/\(f(pct(v, 99)))/\(f(v.max() ?? 0)) >25=\(over25) >50=\(over50)"
    }

    private static func avgMax(_ v: [Double]) -> String {
        guard !v.isEmpty else { return "0.0/0.0" }
        return "\(f(v.reduce(0, +) / Double(v.count)))/\(f(v.max()!))"
    }
}
