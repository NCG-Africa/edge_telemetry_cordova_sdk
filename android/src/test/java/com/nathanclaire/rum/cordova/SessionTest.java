package com.nathanclaire.rum.cordova;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import org.json.JSONObject;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class SessionTest {
    @Rule public TemporaryFolder tmp = new TemporaryFolder();
    final IdGeneratorTest.FakeStore store = new IdGeneratorTest.FakeStore();
    long now = 1793008800000L; // 2026-10-26T10:00:00.000Z
    double roll = 0.0;
    int ids;
    String userId;
    Health health;

    Session session(double rate) {
        if (health == null) health = new Health(new File(tmp.getRoot(), "edge_rum"));
        return new Session(store, health, () -> now, rate, () -> roll, () -> "session_" + ++ids, () -> userId);
    }

    static JSONObject event(String name) throws Exception {
        return new JSONObject().put("type", "event").put("eventName", name).put("timestamp", "t").put("attributes", new JSONObject());
    }

    static JSONObject event(String name, String k, Object v) throws Exception {
        JSONObject e = event(name);
        e.getJSONObject("attributes").put(k, v);
        return e;
    }

    static JSONObject metric(String name) throws Exception {
        return new JSONObject().put("type", "metric").put("metricName", name).put("value", 1).put("attributes", new JSONObject());
    }

    static List<JSONObject> parse(List<String> lines) throws Exception {
        List<JSONObject> out = new ArrayList<>();
        for (String l : lines) out.add(new JSONObject(l));
        return out;
    }

    static List<String> names(List<String> lines) throws Exception {
        List<String> out = new ArrayList<>();
        for (JSONObject e : parse(lines)) out.add(e.optString("eventName", e.optString("metricName")));
        return out;
    }

    static List<JSONObject> repeat(JSONObject e, int n) {
        return new ArrayList<>(Collections.nCopies(n, e));
    }

    @Test public void firstBeginStartsFirstSession() throws Exception {
        JSONObject started = parse(session(1.0).begin()).get(0);
        assertEquals("session.started", started.getString("eventName"));
        JSONObject a = started.getJSONObject("attributes");
        assertEquals("session_1", a.getString("session.id"));
        assertEquals("2026-10-26T10:00:00.000Z", a.getString("session.start_time"));
        assertTrue(a.getBoolean("session.is_first_session"));
        assertEquals(1, a.getInt("session.total_sessions"));
        assertFalse("S3: absent at rate 1", a.has("session.sampled"));
    }

    @Test public void stampsSessionAndUserOnEveryEvent() throws Exception {
        Session s = session(1.0);
        s.begin();
        userId = "u1";
        JSONObject a = parse(s.admit(Collections.singletonList(event("navigation")))).get(0).getJSONObject("attributes");
        assertEquals("session_1", a.getString("session.id"));
        assertEquals("u1", a.getString("user.id"));
    }

    @Test public void idleTimeoutRotatesWithBackdatedFinalizeAndFreshCounters() throws Exception {
        Session s = session(1.0);
        s.begin();
        s.admit(java.util.Arrays.asList(event("navigation", "navigation.to_screen", "/home"), metric("LCP")));
        now += 60_000;
        s.admit(Collections.singletonList(event("navigation", "navigation.to_screen", "/cart")));
        now += Session.IDLE_MS + 1;

        List<String> out = s.admit(Collections.singletonList(event("custom_event")));
        assertEquals(java.util.Arrays.asList("session.finalized", "session.started", "custom_event"), names(out));
        JSONObject fin = parse(out).get(0).getJSONObject("attributes");
        assertEquals("session_1", fin.getString("session.id"));
        assertEquals(60_000, fin.getLong("session.duration_ms"));
        assertEquals(2, fin.getInt("session.event_count"));
        assertEquals(1, fin.getInt("session.metric_count"));
        assertEquals(2, fin.getInt("session.screen_count"));
        assertEquals("/home,/cart", fin.getString("session.visited_screens"));
        JSONObject started = parse(out).get(1).getJSONObject("attributes");
        assertEquals("session_2", started.getString("session.id"));
        assertFalse(started.getBoolean("session.is_first_session"));
        assertEquals(2, started.getInt("session.total_sessions"));
        assertEquals("session_2", parse(out).get(2).getJSONObject("attributes").getString("session.id"));
        assertEquals("session_2", s.id());
    }

    @Test public void rotateIfIdleOnlyRotatesPastTheTimeout() throws Exception {
        Session s = session(1.0);
        s.begin();
        now += Session.IDLE_MS;
        assertTrue(s.rotateIfIdle().isEmpty());
        now += 1;
        assertEquals(java.util.Arrays.asList("session.finalized", "session.started"), names(s.rotateIfIdle()));
    }

    @Test public void sessionAndRollSurviveWebViewReloadAndRelaunchWithinTimeout() throws Exception {
        roll = 0.9;
        Session s = session(0.5);
        s.begin();
        assertFalse(s.sampled());
        s.admit(Collections.singletonList(event("navigation")));

        now += 1_000;
        roll = 0.0; // a fresh roll would keep the session; the persisted one must win
        Session again = session(0.5);
        assertTrue("resumed, no bookends", again.begin().isEmpty());
        assertEquals("session_1", again.id());
        assertFalse(again.sampled());
    }

    @Test public void relaunchAfterTimeoutFinalizesRecordedSession() throws Exception {
        Session s = session(1.0);
        s.begin();
        s.admit(Collections.singletonList(event("navigation")));
        now += Session.IDLE_MS + 1;

        List<String> out = session(1.0).begin();
        assertEquals(java.util.Arrays.asList("session.finalized", "session.started"), names(out));
        assertEquals(1, parse(out).get(0).getJSONObject("attributes").getInt("session.event_count"));
    }

    @Test public void sampledOutKeepsOnlyExemptAndCountsEverythingUncounted() throws Exception {
        roll = 0.9;
        Session s = session(0.5);
        JSONObject started = parse(s.begin()).get(0);
        assertFalse(started.getJSONObject("attributes").getBoolean("session.sampled"));

        List<JSONObject> in = java.util.Arrays.asList(
                event("navigation"), metric("LCP"), event("app.hang"),
                event("app.crash", "is_fatal", false),
                event("app.crash", "is_fatal", true), event("app.anr"), event("app.exit"), event("app.start"),
                event("cordova.deviceready_timeout"), event("sdk.health"));
        assertEquals(java.util.Arrays.asList("app.crash", "app.anr", "app.exit", "app.start",
                "cordova.deviceready_timeout", "sdk.health"), names(s.admit(in)));
        assertEquals("S7: sampled-out drops not counted", Collections.emptyMap(), health.snapshot());

        now += Session.IDLE_MS + 1;
        JSONObject fin = parse(s.rotateIfIdle()).get(0).getJSONObject("attributes");
        assertEquals("S6: counted before gates", 9, fin.getInt("session.event_count"));
        assertEquals(1, fin.getInt("session.metric_count"));
        assertFalse(fin.getBoolean("session.sampled"));
    }

    @Test public void sampledInAtFractionalRateSaysSo() throws Exception {
        roll = 0.1;
        Session s = session(0.5);
        assertTrue(parse(s.begin()).get(0).getJSONObject("attributes").getBoolean("session.sampled"));
        assertEquals(1, s.admit(Collections.singletonList(event("navigation"))).size());
    }

    @Test public void sampleRateIsClamped() throws Exception {
        roll = 0.0;
        Session none = session(-1);
        none.begin();
        assertFalse(none.sampled());
        store.values.clear();
        roll = 0.999;
        Session all = session(7);
        assertFalse("clamped to 1: no session.sampled",
                parse(all.begin()).get(0).getJSONObject("attributes").has("session.sampled"));
        assertTrue(all.sampled());
    }

    @Test public void interactionCap() throws Exception {
        assertCap(event("ui.interaction"), 200, "events_dropped.cap.interaction");
    }

    @Test public void customCapIsCombinedAcrossCustomHostMetricsAndTasks() throws Exception {
        Session s = session(1.0);
        s.begin();
        assertEquals(500, s.admit(repeat(event("custom_event"), 300)).size()
                + s.admit(repeat(metric("checkout_ms"), 150)).size()
                + s.admit(repeat(event("task.complete"), 50)).size());
        assertEquals(0, s.admit(java.util.Arrays.asList(event("custom_event"), metric("cart"), event("task.complete"))).size());
        assertEquals(1, s.admit(Collections.singletonList(metric("LCP"))).size());
        assertEquals(Collections.singletonMap("events_dropped.cap.custom", 3L), health.snapshot());
    }

    @Test public void errorCapPerDedupKeyThenTotal() throws Exception {
        Session s = session(1.0);
        s.begin();
        JSONObject a = crash("TypeError", "TypeError: x\n    at f (app:///main.js:1:2)");
        assertEquals(5, s.admit(repeat(a, 6)).size());
        // Same type, different top frame → own key.
        assertEquals(5, s.admit(repeat(crash("TypeError", "TypeError: x\n    at g (app:///main.js:9:9)"), 5)).size());
        for (int i = 0; i < 8; i++) s.admit(repeat(crash("E" + i, ""), 5));
        assertEquals("50 total", 0, s.admit(Collections.singletonList(crash("New", ""))).size());
        assertEquals("fatal never capped", 1, s.admit(Collections.singletonList(event("app.crash", "is_fatal", true))).size());
        assertEquals(Collections.singletonMap("events_dropped.cap.error", 2L), health.snapshot());
    }

    @Test public void bridgeCapPerServiceActionThenTotal() throws Exception {
        Session s = session(1.0);
        s.begin();
        assertEquals(5, s.admit(repeat(bridge("Camera", "take"), 7)).size());
        assertEquals(5, s.admit(repeat(bridge("Camera", "pick"), 5)).size());
        for (int i = 0; i < 8; i++) s.admit(repeat(bridge("S" + i, "a"), 5));
        assertEquals(0, s.admit(Collections.singletonList(bridge("Other", "a"))).size());
        assertEquals(Collections.singletonMap("events_dropped.cap.bridge", 3L), health.snapshot());
    }

    @Test public void screenCountKeepsCountingPastTheVisitedList() throws Exception {
        Session s = session(1.0);
        s.begin();
        s.admit(repeat(event("navigation", "navigation.to_screen", "/a"), 60));
        now += Session.IDLE_MS + 1;
        JSONObject fin = parse(s.rotateIfIdle()).get(0).getJSONObject("attributes");
        assertEquals(60, fin.getInt("session.screen_count"));
        assertEquals(50, fin.getString("session.visited_screens").split(",").length);
    }

    @Test public void anAtSignInTheMessageIsNotTheTopFrame() throws Exception {
        Session s = session(1.0);
        s.begin();
        assertEquals("distinct frames under one message → distinct keys", 10, s.admit(java.util.Arrays.asList(
                crash("E", "Error: bad a@b.io\n    at f (app:///x.js:1:1)"), crash("E", "Error: bad a@b.io\n    at f (app:///x.js:1:1)"),
                crash("E", "Error: bad a@b.io\n    at f (app:///x.js:1:1)"), crash("E", "Error: bad a@b.io\n    at f (app:///x.js:1:1)"),
                crash("E", "Error: bad a@b.io\n    at f (app:///x.js:1:1)"),
                crash("E", "Error: bad a@b.io\n    at g (app:///x.js:2:1)"), crash("E", "Error: bad a@b.io\n    at g (app:///x.js:2:1)"),
                crash("E", "Error: bad a@b.io\n    at g (app:///x.js:2:1)"), crash("E", "Error: bad a@b.io\n    at g (app:///x.js:2:1)"),
                crash("E", "g@app:///x.js:2:1"))).size());
    }

    @Test public void uncappedEventsPassFreely() throws Exception {
        Session s = session(1.0);
        s.begin();
        assertEquals(1000, s.admit(repeat(event("http.request"), 1000)).size());
    }

    @Test public void capsSurviveReloadAndResetOnRotation() throws Exception {
        Session s = session(1.0);
        s.begin();
        s.admit(repeat(event("ui.interaction"), 200));
        Session reloaded = session(1.0);
        reloaded.begin();
        assertEquals(0, reloaded.admit(Collections.singletonList(event("ui.interaction"))).size());
        now += Session.IDLE_MS + 1;
        assertEquals(3, reloaded.admit(Collections.singletonList(event("ui.interaction"))).size());
    }

    @Test public void restartStartsFreshWithoutFinalizingAndEndForgets() throws Exception {
        Session s = session(1.0);
        s.begin();
        assertEquals(Collections.singletonList("session.started"), names(s.restart()));
        assertEquals("session_2", s.id());
        s.end();
        assertNull(s.id());
        assertTrue(s.admit(Collections.singletonList(event("navigation"))).isEmpty());
        assertEquals("ended session not finalized on relaunch",
                Collections.singletonList("session.started"), names(session(1.0).begin()));
    }

    @Test public void bookendsMatchGoldenBatch() throws Exception {
        assertBookendsGolden(1.0, 0.0, "session.json");
    }

    @Test public void sampledBookendsMatchGoldenBatch() throws Exception {
        assertBookendsGolden(0.5, 0.9, "session-sampled.json");
    }

    void assertBookendsGolden(double rate, double r, String golden) throws Exception {
        roll = r;
        userId = "u1";
        Session s = session(rate);
        List<String> lines = new ArrayList<>(s.begin());
        lines.addAll(s.admit(Collections.singletonList(event("navigation", "navigation.to_screen", "/home"))));
        now += 5_000;
        lines.addAll(s.admit(Collections.singletonList(metric("LCP"))));
        now += Session.IDLE_MS + 1;
        lines.addAll(s.rotateIfIdle());

        Outbox outbox = new Outbox(new File(tmp.getRoot(), "edge_rum"), () -> now, health);
        outbox.append(SenderTest.IDENTITY, lines);
        outbox.seal();
        MockWebServer server = new MockWebServer();
        server.start();
        try {
            Sender sender = new Sender(outbox, health, "1.0.0", () -> now, ms -> { }, new long[] {1});
            sender.configure("k", server.url("/").toString());
            server.enqueue(new MockResponse().setResponseCode(200));
            sender.drain();
            SenderTest.assertGolden(golden, SenderTest.gunzip(server.takeRequest()));
        } finally {
            server.shutdown();
        }
    }

    void assertCap(JSONObject e, int limit, String reason) throws Exception {
        Session s = session(1.0);
        s.begin();
        assertEquals(limit, s.admit(repeat(e, limit + 2)).size());
        assertEquals(Collections.singletonMap(reason, 2L), health.snapshot());
    }

    static JSONObject crash(String type, String stack) throws Exception {
        JSONObject e = event("app.crash", "is_fatal", false);
        e.getJSONObject("attributes").put("handled", true).put("exception_type", type).put("stacktrace", stack);
        return e;
    }

    static JSONObject bridge(String service, String action) throws Exception {
        JSONObject e = event("bridge.call", "bridge.service", service);
        e.getJSONObject("attributes").put("bridge.action", action);
        return e;
    }
}
