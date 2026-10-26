@testable import EdgeRum
import XCTest

final class WatchdogTests: XCTestCase {
    var now: Int64 = 0
    var posted: [() -> Void] = []
    var fired: [Int64] = []

    func watchdog(_ hangMs: Int64) -> Watchdog {
        Watchdog(hangMs: hangMs, postToMain: { [unowned self] in posted.append($0) }, clock: { [unowned self] in now },
                 onHang: { [unowned self] in fired.append($0) })
    }

    /// Scans every 1 s of a stall of `ms`, main thread never answering.
    func stall(_ w: Watchdog, _ ms: Int64) {
        w.scanOnce()
        var t: Int64 = 0
        while t < ms {
            now += 1_000
            w.scanOnce()
            t += 1_000
        }
    }

    func testStallPastTheLineFiresOnce() {
        stall(watchdog(2_000), 7_000)
        XCTAssertEqual(fired, [2_000])
    }

    func testBelowTheLineNothingFires() {
        stall(watchdog(2_000), 1_000)
        XCTAssertEqual(fired, [])
    }

    func testAnsweredHeartbeatRearmsForTheNextStall() {
        let w = watchdog(2_000)
        stall(w, 3_000)
        posted[0]() // main thread free again
        stall(w, 2_000)
        XCTAssertEqual(fired, [2_000, 2_000])
        XCTAssertEqual(posted.count, 2, "one heartbeat per stall")
    }

    func testConfiguredThreshold() {
        stall(watchdog(3_500), 5_000)
        XCTAssertEqual(fired, [4_000], "first scan at or past the line")
    }

    func testIntervalIsHalfTheLineAndZeroWhenOff() {
        XCTAssertEqual(watchdog(2_000).intervalMs, 1_000)
        XCTAssertEqual(watchdog(0).intervalMs, 0, "off: never started")
    }
}
