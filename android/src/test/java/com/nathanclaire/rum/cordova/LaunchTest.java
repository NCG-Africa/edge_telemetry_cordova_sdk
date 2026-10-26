package com.nathanclaire.rum.cordova;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.json.JSONObject;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class LaunchTest {
    @Rule public TemporaryFolder tmp = new TemporaryFolder();
    final IdGeneratorTest.FakeStore store = new IdGeneratorTest.FakeStore();
    static final long T0 = 1793008800000L; // 2026-10-26T10:00:00.000Z, process start
    final Launch launch = new Launch(T0, T0 + 120);

    void pagePhases() throws Exception {
        assertNull(launch.mark("responseEnd", T0 + 300));
        assertNull(launch.mark("DOMContentLoaded", T0 + 450));
        assertNull(launch.mark("load", T0 + 600));
    }

    @Test public void devicereadyAloneWaitsForTheWindow() throws Exception {
        pagePhases();
        assertNull("markReady may still come", launch.mark("deviceready", T0 + 700));
        assertTrue(launch.devicereadySeen());
        JSONObject a = launch.finish().getJSONObject("attributes");
        assertEquals(700, a.getLong("app.start.duration_ms"));
        assertEquals(120, a.getLong("app.start.webview_created_ms"));
        assertFalse(a.has("app.start.mark_ready_ms"));
        assertNull("once per launch", launch.finish());
    }

    @Test public void markReadyInsideWindowCompletesIt() throws Exception {
        pagePhases();
        launch.mark("deviceready", T0 + 700);
        JSONObject e = launch.mark("markReady", T0 + 2000);
        assertEquals(2000, e.getJSONObject("attributes").getLong("app.start.duration_ms"));
        assertEquals(Sender.rfc3339(T0 + 2000), e.getString("timestamp"));
        assertNull(launch.finish());
    }

    @Test public void markReadyBeforeDevicereadyCountsAtDeviceready() throws Exception {
        assertNull(launch.mark("markReady", T0 + 500));
        assertNotNull(launch.mark("deviceready", T0 + 700));
    }

    @Test public void lateMarkReadyIgnored() throws Exception {
        launch.mark("deviceready", T0 + 700);
        assertNull(launch.mark("markReady", T0 + 700 + Launch.READY_WINDOW_MS + 1));
        assertFalse(launch.finish().getJSONObject("attributes").has("app.start.mark_ready_ms"));
    }

    @Test public void reloadAndUnknownPhasesIgnored() throws Exception {
        launch.mark("load", T0 + 600);
        launch.mark("load", T0 + 9000);
        launch.mark("bogus", T0 + 1);
        assertNull(launch.mark(null, T0 + 1));
        assertNull("no deviceready, no app.start", launch.finish());
        launch.mark("deviceready", T0 + 700);
        JSONObject a = launch.finish().getJSONObject("attributes");
        assertEquals(600, a.getLong("app.start.load_ms"));
        assertFalse(a.has("bogus"));
    }

    @Test public void timeoutMarkerReportedOnceNextLaunch() throws Exception {
        assertNull(Launch.takeTimeout(store));
        Launch.timedOut(store, 10_000, T0 + 10_000);
        JSONObject e = Launch.takeTimeout(store);
        assertEquals("cordova.deviceready_timeout", e.getString("eventName"));
        assertEquals(10_000, e.getJSONObject("attributes").getLong("cordova.deviceready_timeout_ms"));
        assertNull(Launch.takeTimeout(store));
    }

    @Test public void corruptMarkerDropped() {
        store.values.put(Launch.KEY_TIMEOUT, "garbage");
        assertNull(Launch.takeTimeout(store));
        assertNull(store.values.get(Launch.KEY_TIMEOUT));
    }

    @Test public void goldenBatches() throws Exception {
        long now = T0 + 2000;
        File dir = new File(tmp.getRoot(), "edge_rum");
        Health health = new Health(dir);
        Session session = new Session(store, health, () -> now, 0.0, () -> 0.9, () -> "session_1", () -> null);
        session.begin();
        pagePhases();
        launch.mark("deviceready", T0 + 700);
        Launch.timedOut(store, 10_000, T0 - 50_000);
        // S2: both exempt, so they survive a sampled-out session.
        List<String> lines = new ArrayList<>(session.admit(Arrays.asList(launch.mark("markReady", T0 + 1500))));
        SenderTest.assertGoldenBatch("app-start.json", dir, health, now, lines);
        lines = session.admit(Arrays.asList(Launch.takeTimeout(store)));
        SenderTest.assertGoldenBatch("cordova-deviceready-timeout.json", dir, health, now, lines);
    }
}
