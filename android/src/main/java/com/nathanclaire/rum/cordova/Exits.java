package com.nathanclaire.rum.cordova;

import java.util.ArrayList;
import java.util.List;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Spec E16: `app.exit` from `ActivityManager.getHistoricalProcessExitReasons` (API 30+), one per
 * exit record newer than the persisted watermark. Attribute set follows the sibling
 * `ApplicationExitHarvester`; the plugin maps `ApplicationExitInfo` to {@link Record}.
 */
final class Exits {
    static final String KEY_WATERMARK = "exit_watermark";
    /** Sibling cap: double the stack cap; the culprit sits at the head. */
    private static final int MAX_TRACE = 4000;
    /** `ApplicationExitInfo.REASON_*`, by value (0–16). */
    private static final String[] REASONS = {"unknown", "exit_self", "signaled", "low_memory", "crash", "crash_native",
            "anr", "initialization_failure", "permission_change", "excessive_resource_usage", "user_requested",
            "user_stopped", "dependency_died", "other", "freezer", "package_state_change", "package_updated"};

    static final class Record {
        final int reason;
        final int importance;
        final int status;
        final String description;
        final long pssKb;
        final long rssKb;
        final long timestamp;
        /** ANR records only (the OS's text trace); null otherwise. */
        final String trace;

        Record(int reason, int importance, int status, String description, long pssKb, long rssKb, long timestamp,
                String trace) {
            this.reason = reason;
            this.importance = importance;
            this.status = status;
            this.description = description;
            this.pssKb = pssKb;
            this.rssKb = rssKb;
            this.timestamp = timestamp;
            this.trace = trace;
        }
    }

    private Exits() {
    }

    /** Events for records newer than the watermark, which then advances to the newest of them. */
    static List<JSONObject> harvest(List<Record> records, IdGenerator.Store store, long now) throws JSONException {
        long watermark = -1;
        try {
            String saved = store.get(KEY_WATERMARK);
            if (saved != null) watermark = Long.parseLong(saved);
        } catch (RuntimeException ignored) {
            // unreadable: everything still in the OS buffer counts as new
        }
        List<JSONObject> out = new ArrayList<>();
        long newest = watermark;
        for (Record r : records) {
            if (r.timestamp <= watermark) continue;
            newest = Math.max(newest, r.timestamp);
            out.add(new JSONObject()
                    .put("type", "event")
                    .put("eventName", "app.exit")
                    .put("timestamp", Sender.rfc3339(now))
                    .put("attributes", attributes(r)));
        }
        if (newest != watermark) {
            try {
                store.put(KEY_WATERMARK, String.valueOf(newest));
            } catch (RuntimeException ignored) {
                // re-sent next launch; better than lost
            }
        }
        return out;
    }

    private static JSONObject attributes(Record r) throws JSONException {
        JSONObject a = new JSONObject()
                .put("exit.reason", r.reason >= 0 && r.reason < REASONS.length ? REASONS[r.reason] : "unknown_" + r.reason)
                .put("exit.importance", importance(r.importance))
                .put("exit.description", r.description)
                .put("exit.status", r.status)
                .put("exit.pss_kb", r.pssKb)
                .put("exit.rss_kb", r.rssKb)
                .put("exit.timestamp", r.timestamp);
        if (r.trace != null) {
            a.put("exit.trace", r.trace.length() <= MAX_TRACE ? r.trace : r.trace.substring(0, MAX_TRACE) + "\n…[trace truncated]");
        }
        return a;
    }

    /** `RunningAppProcessInfo.IMPORTANCE_*`, by value. */
    private static String importance(int code) {
        switch (code) {
            case 100: return "foreground";
            case 125: return "foreground_service";
            case 200: return "visible";
            case 230: return "perceptible";
            case 300: return "service";
            case 400: return "cached";
            case 1000: return "gone";
            default: return "unknown_" + code;
        }
    }
}
