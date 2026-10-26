package com.nathanclaire.rum.cordova;

import java.util.ArrayList;
import java.util.List;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Spec E2, E22–E24, E26: native `app_lifecycle`, `memory_usage`, `memory_pressure` and
 * `network_change` records, N1 keys. The plugin reads the platform; these only shape it.
 */
final class Signals {
    private Signals() {
    }

    /** E2: native fg/bg (`foregrounded` / `backgrounded`, iOS vocabulary, N3); JS sends its own states. */
    static JSONObject lifecycle(String state, long at) throws JSONException {
        return Crash.event("app_lifecycle", at, new JSONObject().put("lifecycle.state", state));
    }

    /** E22 / E23: one `memory_usage` per measure (RSS, PSS), in MB. A missing reading (< 0) is skipped. */
    static List<JSONObject> memory(long rssKb, long pssKb, String source, long at) throws JSONException {
        List<JSONObject> out = new ArrayList<>(2);
        if (rssKb >= 0) out.add(memoryMetric(rssKb, "rss", source, at));
        if (pssKb >= 0) out.add(memoryMetric(pssKb, "pss", source, at));
        return out;
    }

    private static JSONObject memoryMetric(long kb, String type, String source, long at) throws JSONException {
        double mb = mb(kb);
        return new JSONObject()
                .put("type", "metric")
                .put("metricName", "memory_usage")
                .put("value", mb)
                .put("timestamp", Sender.rfc3339(at))
                .put("attributes", new JSONObject()
                        .put("metric.unit", "MB")
                        .put("memory.usage_mb", mb)
                        .put("memory.type", type)
                        .put("memory.source", source));
    }

    /** E24: `ComponentCallbacks2` trim level → `memory_pressure`; UI_HIDDEN (20) is a backgrounding, not pressure → null. */
    static JSONObject pressure(int level, long rssKb, long at) throws JSONException {
        String name = pressureLevel(level);
        if (name == null) return null;
        JSONObject a = new JSONObject().put("memory.pressure_level", name).put("memory.trim_level", level);
        if (rssKb >= 0) a.put("memory.usage_mb", mb(rssKb)).put("memory.type", "rss");
        return Crash.event("memory_pressure", at, a.put("memory.source", "on_trim_memory"));
    }

    /** `TRIM_MEMORY_*` by value; `onLowMemory` arrives as 80 (complete). */
    private static String pressureLevel(int level) {
        switch (level) {
            case 5: return "running_moderate";
            case 10: return "running_low";
            case 15: return "running_critical";
            case 40: return "background";
            case 60: return "moderate";
            case 80: return "complete";
            default: return null;
        }
    }

    /** E26: default network transport changed (`wifi` / `cellular` / `ethernet` / `other` / `none`). */
    static JSONObject network(String previous, String current, long at) throws JSONException {
        return Crash.event("network_change", at, new JSONObject()
                .put("network.type", current)
                .put("network.previous_type", previous));
    }

    /** `VmRSS:` of `/proc/self/status`, in kB; -1 when absent. */
    static long rssKb(String procStatus) {
        for (String line : procStatus.split("\n")) {
            if (!line.startsWith("VmRSS:")) continue;
            try {
                return Long.parseLong(line.substring(6).trim().split("\\s+")[0]);
            } catch (RuntimeException e) {
                return -1;
            }
        }
        return -1;
    }

    private static double mb(long kb) {
        return Math.round(kb / 102.4) / 10.0;
    }
}
