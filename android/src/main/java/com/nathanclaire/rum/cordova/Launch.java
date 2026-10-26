package com.nathanclaire.rum.cordova;

import java.util.HashMap;
import java.util.Map;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Spec A5, A7, E3, E17: the one `app.start` per cold launch, assembled from the native process
 * start + WebView created marks and the JS `markPhase` phases; and the persisted marker a
 * launch without `deviceready` leaves for the next one.
 */
final class Launch {
    static final String KEY_TIMEOUT = "deviceready_timeout";
    /** A5: `markReady()` counts when it lands within this long of `deviceready`. */
    static final long READY_WINDOW_MS = 30_000;
    static final String DEVICEREADY = "deviceready";
    static final String READY = "markReady";
    /** JS phases (A5) → `app.start.*` keys, in launch order. */
    private static final String[][] PHASES = {
            {"responseEnd", "app.start.response_end_ms"},
            {"DOMContentLoaded", "app.start.dom_content_loaded_ms"},
            {"load", "app.start.load_ms"},
            {DEVICEREADY, "app.start.deviceready_ms"},
            {READY, "app.start.mark_ready_ms"}};

    private final long processStart;
    private final long webViewCreated;
    private final Map<String, Long> marks = new HashMap<>();
    private boolean emitted;

    Launch(long processStart, long webViewCreated) {
        this.processStart = processStart;
        this.webViewCreated = webViewCreated;
    }

    /**
     * Records a phase (first mark wins: a WebView reload re-sends them). Returns `app.start` when
     * this mark completes it: `markReady` with `deviceready` seen, inside the window.
     */
    synchronized JSONObject mark(String phase, long ts) throws JSONException {
        if (emitted || phase == null || marks.containsKey(phase) || key(phase) == null) return null;
        Long deviceready = marks.get(DEVICEREADY);
        if (READY.equals(phase) && deviceready != null && ts - deviceready > READY_WINDOW_MS) return null;
        marks.put(phase, ts);
        return marks.containsKey(DEVICEREADY) && marks.containsKey(READY) ? emit() : null;
    }

    synchronized boolean devicereadySeen() {
        return marks.containsKey(DEVICEREADY);
    }

    /** Window over (or app backgrounded): `app.start` without `markReady`, if `deviceready` came and it's still owed. */
    synchronized JSONObject finish() throws JSONException {
        return emitted || !marks.containsKey(DEVICEREADY) ? null : emit();
    }

    private JSONObject emit() throws JSONException {
        emitted = true;
        long end = marks.containsKey(READY) ? Math.max(marks.get(READY), marks.get(DEVICEREADY)) : marks.get(DEVICEREADY);
        JSONObject a = new JSONObject()
                .put("app.start.type", "cold")
                .put("app.start.duration_ms", Math.max(0, end - processStart))
                .put("app.start.webview_created_ms", Math.max(0, webViewCreated - processStart));
        for (String[] p : PHASES) {
            Long ts = marks.get(p[0]);
            if (ts != null) a.put(p[1], Math.max(0, ts - processStart));
        }
        return Crash.event("app.start", end, a);
    }

    private static String key(String phase) {
        for (String[] p : PHASES) if (p[0].equals(phase)) return p[1];
        return null;
    }

    /** A7: no `deviceready` by the timeout → a marker for the next launch to report. */
    static void timedOut(IdGenerator.Store store, long timeoutMs, long now) {
        try {
            store.put(KEY_TIMEOUT, new JSONObject().put("at", now).put("timeout_ms", timeoutMs).toString());
        } catch (JSONException | RuntimeException ignored) {
            // best effort: a lost marker is one unreported slow launch
        }
    }

    /** E17: last launch's marker as `cordova.deviceready_timeout`, or null; the marker is gone either way. */
    static JSONObject takeTimeout(IdGenerator.Store store) {
        try {
            String raw = store.get(KEY_TIMEOUT);
            if (raw == null) return null;
            store.put(KEY_TIMEOUT, null);
            JSONObject m = new JSONObject(raw);
            return Crash.event("cordova.deviceready_timeout", m.getLong("at"),
                    new JSONObject().put("cordova.deviceready_timeout_ms", m.getLong("timeout_ms")));
        } catch (JSONException | RuntimeException e) {
            return null;
        }
    }
}
