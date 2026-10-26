package com.nathanclaire.rum.cordova;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.DoubleSupplier;
import java.util.function.LongSupplier;
import java.util.function.Supplier;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Spec E1, S1–S8: the native session and the gate every event passes at outbox append. One
 * record (id, roll, counters, caps) persisted per hand-off, so a WebView reload or a relaunch
 * inside the idle timeout resumes the same session.
 */
final class Session {
    static final long IDLE_MS = 30 * 60_000;
    static final String KEY_RECORD = "session";
    static final String KEY_TOTAL = "total_sessions";
    /** `session.visited_screens` keeps the first 50; `session.screen_count` counts them all (S6). */
    private static final int MAX_SCREENS = 50;
    /** S4 per-session caps. */
    static final int CAP_ERRORS = 50;
    static final int CAP_ERRORS_PER_KEY = 5;
    static final int CAP_INTERACTIONS = 200;
    static final int CAP_BRIDGE = 50;
    static final int CAP_BRIDGE_PER_CALL = 5;
    static final int CAP_CUSTOM = 500;
    /** A JSC frame (`fn@url:line[:col]`); a V8 message line with an `@` in it doesn't match. */
    private static final Pattern JSC_FRAME = Pattern.compile("^[^\\s@]*@\\S+:\\d+(:\\d+)?$");

    /** S2: never sampled out, never capped (fatal `app.crash` checked separately). */
    private static final Set<String> EXEMPT = new HashSet<>(Arrays.asList("session.started", "session.finalized",
            "app.anr", "app.exit", "app.start", "cordova.deviceready_timeout", "sdk.health"));
    /** E7, E21, E22: SDK metrics; any other metric name is the host's (`measure()` / `time()`). */
    private static final Set<String> SDK_METRICS = new HashSet<>(Arrays.asList(
            "LCP", "INP", "CLS", "FCP", "TTFB", "resource_timing", "memory_usage"));

    private final IdGenerator.Store store;
    private final Health health;
    private final LongSupplier clock;
    private final double rate;
    private final DoubleSupplier roll;
    private final Supplier<String> newId;
    private final Supplier<String> userId;

    /** E32: device / network context stamped on every event; an event's own key wins. */
    private Supplier<JSONObject> context = JSONObject::new;

    private String id;
    private long startedAt;
    private long lastActivityAt;
    private boolean sampled;
    private int eventCount;
    private int metricCount;
    private int screenCount;
    private List<String> screens = new ArrayList<>();
    private Map<String, Integer> caps = new HashMap<>();

    Session(IdGenerator.Store store, Health health, LongSupplier clock, double sampleRate, DoubleSupplier roll,
            Supplier<String> newId, Supplier<String> userId) {
        this.store = store;
        this.health = health;
        this.clock = clock;
        // C1: clamped 0..1; NaN (unparseable pref) keeps everything.
        this.rate = Double.isNaN(sampleRate) ? 1 : Math.max(0, Math.min(1, sampleRate));
        this.roll = roll;
        this.newId = newId;
        this.userId = userId;
    }

    synchronized void context(Supplier<JSONObject> context) {
        this.context = context;
    }

    synchronized String id() {
        return id;
    }

    synchronized boolean sampled() {
        return sampled;
    }

    /** Launch / `enable()`: resumes the recorded session if still live, else finalizes it and starts one. */
    synchronized List<String> begin() {
        if (id == null) load();
        if (id != null) return rotateIfIdle();
        List<String> out = new ArrayList<>();
        start(out);
        return out;
    }

    /** Rotation check without activity (foreground). Bookends to append, or none. */
    synchronized List<String> rotateIfIdle() {
        List<String> out = new ArrayList<>();
        if (id != null && clock.getAsLong() - lastActivityAt > IDLE_MS) {
            out.add(finalized());
            start(out);
        }
        return out;
    }

    /** `reset()`: a fresh session; the old one is discarded with the outbox, not finalized. */
    synchronized List<String> restart() {
        List<String> out = new ArrayList<>();
        start(out);
        return out;
    }

    /** `disable()`: forgets the session; nothing is finalized for it. */
    synchronized void end() {
        id = null;
        put(KEY_RECORD, null);
    }

    /**
     * The gate (S5): counts each event (S6), drops it if sampled out or capped, stamps
     * `session.id` / `user.id` on what's kept. Returns the lines to append, bookends first.
     */
    synchronized List<String> admit(List<JSONObject> events) {
        if (id == null) return Collections.emptyList();
        List<String> out = rotateIfIdle();
        for (JSONObject e : events) {
            JSONObject attrs = e.optJSONObject("attributes");
            if (attrs == null) attrs = new JSONObject();
            boolean metric = "metric".equals(e.optString("type"));
            String name = e.optString(metric ? "metricName" : "eventName");
            count(metric, name, attrs);
            if (!exempt(name, attrs)) {
                if (!sampled) continue;
                String reason = capReason(metric, name, attrs);
                if (reason != null) {
                    health.count(reason, 1);
                    continue;
                }
            }
            try {
                e.put("attributes", stamp(attrs, id));
            } catch (JSONException ex) {
                continue; // unreachable: string keys and values
            }
            out.add(e.toString());
        }
        lastActivityAt = clock.getAsLong();
        persist();
        return out;
    }

    private void count(boolean metric, String name, JSONObject attrs) {
        if (metric) metricCount++;
        else eventCount++;
        String screen = attrs.optString("navigation.to_screen");
        if (!"navigation".equals(name) || screen.isEmpty()) return;
        screenCount++;
        if (screens.size() < MAX_SCREENS) screens.add(screen);
    }

    private static boolean exempt(String name, JSONObject attrs) {
        return EXEMPT.contains(name) || ("app.crash".equals(name) && attrs.optBoolean("is_fatal"));
    }

    /** S4 / S7: the `sdk.health` reason when a cap is hit, else null (and the event is counted). */
    private String capReason(boolean metric, String name, JSONObject attrs) {
        if (metric && SDK_METRICS.contains(name)) return null;
        switch (metric ? "custom_event" : name) {
            case "app.crash":
                String key = "error:" + attrs.optString("exception_type") + "|" + topFrame(attrs.optString("stacktrace"));
                return allow("error", CAP_ERRORS, key, CAP_ERRORS_PER_KEY) ? null : "cap.error";
            case "ui.interaction":
                return allow("interaction", CAP_INTERACTIONS, null, 0) ? null : "cap.interaction";
            case "bridge.call":
                String call = "bridge:" + attrs.optString("bridge.service") + "|" + attrs.optString("bridge.action");
                return allow("bridge", CAP_BRIDGE, call, CAP_BRIDGE_PER_CALL) ? null : "cap.bridge";
            case "custom_event": // and host metrics
            case "task.complete":
                return allow("custom", CAP_CUSTOM, null, 0) ? null : "cap.custom";
            default:
                return null;
        }
    }

    /** Takes a slot from the total and, if given, the per-key cap; neither is taken when either is full. */
    private boolean allow(String total, int totalLimit, String key, int keyLimit) {
        int t = caps.containsKey(total) ? caps.get(total) : 0;
        int k = key != null && caps.containsKey(key) ? caps.get(key) : 0;
        if (t >= totalLimit || (key != null && k >= keyLimit)) return false;
        caps.put(total, t + 1);
        if (key != null) caps.put(key, k + 1);
        return true;
    }

    // ponytail: first line that looks like a frame (V8 `at …`, JSC `fn@url`); frames' parsed form is issue 11's.
    private static String topFrame(String stack) {
        for (String line : stack.split("\n")) {
            String l = line.trim();
            if (l.startsWith("at ") || JSC_FRAME.matcher(l).matches()) return l;
        }
        return "";
    }

    private JSONObject stamp(JSONObject attrs, String sessionId) throws JSONException {
        JSONObject ctx = context.get();
        JSONArray keys = ctx.names();
        for (int i = 0; keys != null && i < keys.length(); i++) {
            String k = keys.getString(i);
            if (!attrs.has(k)) attrs.put(k, ctx.get(k));
        }
        attrs.put("session.id", sessionId);
        String user = userId.get();
        if (user != null) attrs.put("user.id", user);
        return attrs;
    }

    private void start(List<String> out) {
        long now = clock.getAsLong();
        id = newId.get();
        startedAt = now;
        lastActivityAt = now;
        sampled = rate >= 1 || roll.getAsDouble() < rate; // S1
        eventCount = 0;
        metricCount = 0;
        screenCount = 0;
        screens = new ArrayList<>();
        caps = new HashMap<>();
        int total = 1;
        try {
            String saved = store.get(KEY_TOTAL);
            if (saved != null) total = Integer.parseInt(saved) + 1;
        } catch (RuntimeException ignored) {
            // unreadable count: this one counts as first
        }
        put(KEY_TOTAL, String.valueOf(total));
        persist();
        try {
            JSONObject a = sampledAttr(new JSONObject()
                    .put("session.start_time", Sender.rfc3339(startedAt))
                    .put("session.is_first_session", total == 1)
                    .put("session.total_sessions", total));
            out.add(bookend("session.started", now, a));
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
    }

    /** E1: backdated to the last activity, so idle time isn't session time. */
    private String finalized() {
        try {
            JSONObject a = sampledAttr(new JSONObject()
                    .put("session.start_time", Sender.rfc3339(startedAt))
                    .put("session.duration_ms", Math.max(0, lastActivityAt - startedAt))
                    .put("session.event_count", eventCount)
                    .put("session.metric_count", metricCount)
                    .put("session.screen_count", screenCount)
                    .put("session.visited_screens", join(screens)));
            return bookend("session.finalized", lastActivityAt, a);
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
    }

    /** S3: only when the rate is below 1. */
    private JSONObject sampledAttr(JSONObject a) throws JSONException {
        return rate < 1 ? a.put("session.sampled", sampled) : a;
    }

    private String bookend(String name, long at, JSONObject attrs) throws JSONException {
        return new JSONObject()
                .put("type", "event")
                .put("eventName", name)
                .put("timestamp", Sender.rfc3339(at))
                .put("attributes", stamp(attrs, id))
                .toString();
    }

    private static String join(List<String> items) {
        StringBuilder sb = new StringBuilder();
        for (String s : items) sb.append(sb.length() == 0 ? "" : ",").append(s);
        return sb.toString();
    }

    private void persist() {
        try {
            put(KEY_RECORD, new JSONObject()
                    .put("id", id)
                    .put("start", startedAt)
                    .put("last", lastActivityAt)
                    .put("sampled", sampled)
                    .put("events", eventCount)
                    .put("metrics", metricCount)
                    .put("screen_count", screenCount)
                    .put("screens", new JSONArray(screens))
                    .put("caps", new JSONObject(caps))
                    .toString());
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
    }

    /** Storage failures keep the in-memory session going; a relaunch then starts a new one. */
    private void put(String key, String value) {
        try {
            store.put(key, value);
        } catch (RuntimeException ignored) {
            // see above
        }
    }

    private void load() {
        try {
            String raw = store.get(KEY_RECORD);
            if (raw == null) return;
            JSONObject r = new JSONObject(raw);
            startedAt = r.getLong("start");
            lastActivityAt = r.getLong("last");
            sampled = r.getBoolean("sampled");
            eventCount = r.getInt("events");
            metricCount = r.getInt("metrics");
            screenCount = r.getInt("screen_count");
            JSONArray s = r.getJSONArray("screens");
            screens = new ArrayList<>();
            for (int i = 0; i < s.length(); i++) screens.add(s.getString(i));
            JSONObject c = r.getJSONObject("caps");
            caps = new HashMap<>();
            JSONArray keys = c.names();
            for (int i = 0; keys != null && i < keys.length(); i++) caps.put(keys.getString(i), c.getInt(keys.getString(i)));
            id = r.getString("id"); // last: a corrupt record leaves no half-loaded session
        } catch (JSONException | RuntimeException e) {
            id = null;
        }
    }
}
