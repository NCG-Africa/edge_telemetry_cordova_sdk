import Darwin
import Foundation

/// Spec E2, E22–E24, E26: native `app_lifecycle`, `memory_usage`, `memory_pressure` and
/// `network_change` records, N1 keys, same shapes as the Android `Signals`. The plugin reads the
/// platform; these only shape it.
enum Signals {
    /// E2: native fg/bg (`foregrounded` / `backgrounded`); JS sends its own states.
    static func lifecycle(_ state: String, at: Int64) -> [String: Any] {
        Crash.record("app_lifecycle", at, ["lifecycle.state": state])
    }

    /// E22 / E23: one `memory_usage` per measure (footprint, the number jetsam kills on; RSS), in
    /// MB. A missing reading is skipped.
    static func memory(footprint: Int64?, resident: Int64?, source: String, at: Int64) -> [[String: Any]] {
        [("footprint", footprint), ("rss", resident)].compactMap { type, bytes in
            bytes.map { b in
                let mb = mb(b)
                return ["type": "metric", "metricName": "memory_usage", "value": mb, "timestamp": Sender.rfc3339(at),
                        "attributes": ["metric.unit": "MB", "memory.usage_mb": mb, "memory.type": type,
                                       "memory.source": source]]
            }
        }
    }

    /// E24: `UIApplicationDidReceiveMemoryWarning` → `memory_pressure`; iOS has one level.
    static func pressure(footprint: Int64?, at: Int64) -> [String: Any] {
        var a: [String: Any] = ["memory.pressure_level": "warning", "memory.source": "memory_warning"]
        if let footprint {
            a["memory.usage_mb"] = mb(footprint)
            a["memory.type"] = "footprint"
        }
        return Crash.record("memory_pressure", at, a)
    }

    /// E26: path transport changed (`wifi` / `cellular` / `ethernet` / `other` / `none`).
    static func network(previous: String, current: String, at: Int64) -> [String: Any] {
        Crash.record("network_change", at, ["network.type": current, "network.previous_type": previous])
    }

    /// `TASK_VM_INFO.phys_footprint`, bytes.
    static func footprintBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : nil
    }

    /// `MACH_TASK_BASIC_INFO.resident_size`, bytes.
    static func residentBytes() -> Int64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int64(info.resident_size) : nil
    }

    private static func mb(_ bytes: Int64) -> Double {
        (Double(bytes) / 104_857.6).rounded() / 10
    }
}
