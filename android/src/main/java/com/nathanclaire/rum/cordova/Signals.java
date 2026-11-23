package com.nathanclaire.rum.cordova;

import org.json.JSONException;
import org.json.JSONObject;

/**
 * Spec E2, E22–E24, E26: native `app.lifecycle`, `memory.usage`, `memory.pressure` and
 * `network.change` records, catalogue keys. The plugin reads the platform; these only shape it.
 */
final class Signals {
    private Signals() {
    }

    /** E2: native fg/bg (`foregrounded` / `backgrounded`, iOS vocabulary, N3); JS sends its own states. */
    static JSONObject lifecycle(String state, long at) throws JSONException {
        return Crash.event("app.lifecycle", at, new JSONObject().put("lifecycle.state", state));
    }

    /**
     * E22 / E23: one `memory.usage` in MB: total PSS, the catalogue's Android process footprint; RSS
     * when PSS can't be read. `phase` is when it was taken. Null when neither could be read (< 0).
     */
    static JSONObject memory(long rssKb, long pssKb, String phase, long at) throws JSONException {
        if (rssKb < 0 && pssKb < 0) return null;
        JSONObject a = new JSONObject()
                .put("memory.usage_mb", mb(pssKb >= 0 ? pssKb : rssKb))
                .put("memory.source", pssKb >= 0 ? "pss" : "rss")
                .put("memory.phase", phase);
        if (pssKb >= 0) a.put("memory.total_pss_kb", pssKb);
        if (rssKb >= 0) a.put("memory.resident_kb", rssKb);
        return Crash.event("memory.usage", at, a);
    }

    /**
     * E24: `ComponentCallbacks2` trim level → `memory.pressure`, the level mapped as the Android SDK
     * does; UI_HIDDEN (20) is a backgrounding, not pressure → null.
     */
    static JSONObject pressure(int level, long pssKb, long at) throws JSONException {
        String[] names = pressureLevel(level);
        if (names == null) return null;
        JSONObject a = new JSONObject().put("memory.pressure_level", names[1]).put("memory.trim_level", names[0]);
        if (pssKb >= 0) a.put("memory.usage_mb", mb(pssKb)).put("memory.source", "pss");
        return Crash.event("memory.pressure", at, a);
    }

    /** `TRIM_MEMORY_*` by value → {trim level, `normal|moderate|critical`}; `onLowMemory` arrives as 80 (complete). */
    private static String[] pressureLevel(int level) {
        switch (level) {
            case 5: return new String[] {"running_moderate", "moderate"};
            case 10: return new String[] {"running_low", "moderate"};
            case 15: return new String[] {"running_critical", "critical"};
            case 40: return new String[] {"background", "normal"};
            case 60: return new String[] {"moderate", "moderate"};
            case 80: return new String[] {"complete", "critical"};
            default: return null;
        }
    }

    /** E26: default network transport changed (`wifi` / `cellular` / `ethernet` / `other` / `none`). */
    static JSONObject network(String previous, String current, long at) throws JSONException {
        return Crash.event("network.change", at, new JSONObject()
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

    /** Binary MB (1 MB = 1024 kB), one decimal. */
    private static double mb(long kb) {
        return Math.round(kb / 102.4) / 10.0;
    }
}
