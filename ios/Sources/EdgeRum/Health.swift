import Foundation

/// Spec T8 / R4: drop counters by reason, persisted until a batch carrying them as `sdk.health`
/// is accepted. Keys follow the iOS sibling (`events_dropped.<reason>`).
final class Health {
    private let file: URL
    private let lock = NSLock()
    private var dropped: [String: Int] = [:]

    init(dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("health.json")
        // Missing or corrupt: start from zero.
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
            dropped = saved
        }
    }

    func count(_ reason: String, _ n: Int) {
        guard n > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        dropped["events_dropped." + reason, default: 0] += n
        persist()
    }

    func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    /// Removes counts a delivered batch carried; drops counted since stay.
    func subtract(_ sent: [String: Int]) {
        guard !sent.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for (key, n) in sent {
            guard let cur = dropped[key] else { continue }
            dropped[key] = cur - n > 0 ? cur - n : nil
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONSerialization.data(withJSONObject: dropped) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
