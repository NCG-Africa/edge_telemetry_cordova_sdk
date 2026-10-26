import Foundation

/// Spec E15: main-thread watchdog, the Android `Watchdog` on its hang line only (iOS has no ANR).
/// A timer posts a heartbeat to the main queue; how long it takes to run is read against
/// `EdgeRumHangTimeoutMs`. One stall fires once; the latch clears when main answers. A threshold
/// ≤ 0 is off. Foreground only: started on foreground, stopped on background.
final class Watchdog {
    let hangMs: Int64
    private let postToMain: (@escaping () -> Void) -> Void
    private let clock: () -> Int64
    private let onHang: (Int64) -> Void
    private let lock = NSLock()
    private var waiting = false
    private var pendingSince: Int64 = 0
    private var fired = false
    private var timer: DispatchSourceTimer?

    init(hangMs: Int64, postToMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         clock: @escaping () -> Int64 = Watchdog.uptimeMs, onHang: @escaping (Int64) -> Void) {
        self.hangMs = hangMs
        self.postToMain = postToMain
        self.clock = clock
        self.onHang = onHang
    }

    /// Monotonic: a wall-clock change isn't a hang.
    static func uptimeMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    /// Half the line, so a stall at the line is seen within one scan; 0 when off.
    var intervalMs: Int64 {
        hangMs > 0 ? max(1, hangMs / 2) : 0
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil, intervalMs > 0 else { return }
        waiting = false
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.nathanclaire.rum.watchdog"))
        let interval = DispatchTimeInterval.milliseconds(Int(intervalMs))
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.scanOnce() }
        t.resume()
        timer = t
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    /// One heartbeat cycle; tests drive it with a fake clock.
    func scanOnce() {
        lock.lock()
        if !waiting {
            waiting = true
            fired = false
            pendingSince = clock()
            lock.unlock()
            postToMain { [weak self] in self?.pong() }
            return
        }
        let blocked = clock() - pendingSince
        let fire = !fired && blocked >= hangMs
        if fire { fired = true }
        lock.unlock()
        if fire { onHang(blocked) }
    }

    private func pong() {
        lock.lock(); defer { lock.unlock() }
        waiting = false
        fired = false
    }
}
