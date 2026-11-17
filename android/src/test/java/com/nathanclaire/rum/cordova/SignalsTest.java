package com.nathanclaire.rum.cordova;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;

import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.json.JSONObject;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class SignalsTest {
    @Rule public TemporaryFolder tmp = new TemporaryFolder();
    final IdGeneratorTest.FakeStore store = new IdGeneratorTest.FakeStore();
    long now = 1793008802000L; // 2026-10-26T10:00:02.000Z

    static final String PROC_STATUS = "Name:\tfixture.app\nVmPeak:\t 2000000 kB\nVmRSS:\t  187392 kB\nThreads:\t42\n";

    @Test public void parsesRss() {
        assertEquals(187392, Signals.rssKb(PROC_STATUS));
        assertEquals(-1, Signals.rssKb("Name:\tx\n"));
        assertEquals(-1, Signals.rssKb("VmRSS:\tjunk kB\n"));
    }

    @Test public void memoryIsOneUsageEventInPssMbWithRssFallback() throws Exception {
        JSONObject e = Signals.memory(1024, 2048, "periodic", now);
        assertEquals("event", e.getString("type"));
        assertEquals("memory.usage", e.getString("eventName"));
        JSONObject a = e.getJSONObject("attributes");
        assertEquals("1 MB = 1024 kB", 2.0, a.getDouble("memory.usage_mb"), 0);
        assertEquals("pss", a.getString("memory.source"));
        assertEquals("periodic", a.getString("memory.phase"));
        assertEquals(1024, a.getLong("memory.resident_kb"));
        assertEquals(2048, a.getLong("memory.total_pss_kb"));
        JSONObject rssOnly = Signals.memory(1024, -1, "periodic", now).getJSONObject("attributes");
        assertEquals(1.0, rssOnly.getDouble("memory.usage_mb"), 0);
        assertEquals("rss", rssOnly.getString("memory.source"));
        assertNull(Signals.memory(-1, -1, "periodic", now));
    }

    @Test public void trimLevelsMapToTheCatalogueEnum() throws Exception {
        assertNull("UI_HIDDEN is a backgrounding", Signals.pressure(20, 1, now));
        assertNull(Signals.pressure(7, 1, now));
        int[] levels = {5, 10, 15, 40, 60, 80};
        String[] trim = {"running_moderate", "running_low", "running_critical", "background", "moderate", "complete"};
        String[] level = {"moderate", "moderate", "critical", "normal", "moderate", "critical"};
        for (int i = 0; i < levels.length; i++) {
            JSONObject e = Signals.pressure(levels[i], 2048, now);
            assertEquals("memory.pressure", e.getString("eventName"));
            assertEquals(trim[i], e.getJSONObject("attributes").getString("memory.trim_level"));
            assertEquals(level[i], e.getJSONObject("attributes").getString("memory.pressure_level"));
        }
        assertEquals(2.0, Signals.pressure(15, 2048, now).getJSONObject("attributes").getDouble("memory.usage_mb"), 0);
        assertFalse(Signals.pressure(15, -1, now).getJSONObject("attributes").has("memory.usage_mb"));
    }

    @Test public void longTailNames() throws Exception {
        assertEquals("app.lifecycle", Signals.lifecycle("backgrounded", now).getString("eventName"));
        assertEquals("network.change", Signals.network("wifi", "none", now).getString("eventName"));
    }

    @Test public void contextStampedButEventKeysWin() throws Exception {
        Session session = session();
        JSONObject ctx = new JSONObject().put("device.model", "Pixel 9").put("network.type", "wifi");
        session.context(() -> ctx);
        JSONObject e = new JSONObject(session.admit(Collections.singletonList(Signals.network("wifi", "cellular", now))).get(0));
        assertEquals("Pixel 9", e.getJSONObject("attributes").getString("device.model"));
        assertEquals("cellular", e.getJSONObject("attributes").getString("network.type"));
    }

    Session session() {
        Session s = new Session(store, new Health(new File(tmp.getRoot(), "edge_rum")), () -> now, 1.0, () -> 0.0,
                () -> "session_1", () -> null);
        s.begin();
        return s;
    }

    /** E32: the context the plugin assembles, as one fixed device. */
    static JSONObject deviceContext() throws Exception {
        return new JSONObject()
                .put("device.platform", "android")
                .put("device.platform_version", "16")
                .put("device.model", "Pixel 9")
                .put("device.manufacturer", "Google")
                .put("device.brand", "google")
                .put("device.android_sdk", 36)
                .put("device.android_release", "16")
                .put("device.hardware", "tokay")
                .put("device.product", "tokay")
                .put("device.locale", "en-KE")
                .put("device.timezone", "Africa/Nairobi")
                .put("device.low_ram", false)
                .put("device.cpu_abi", "arm64-v8a")
                .put("device.cpu_cores", 8)
                .put("device.screen_density", 420)
                .put("device.screen_width_px", 1080)
                .put("device.screen_height_px", 2424)
                .put("network.type", "wifi");
    }

    @Test public void goldenBatches() throws Exception {
        File dir = new File(tmp.getRoot(), "edge_rum");
        Health health = new Health(dir);
        Session session = session();
        JSONObject ctx = deviceContext();
        session.context(() -> ctx);
        List<String> lines = new ArrayList<>(session.admit(Collections.singletonList(Signals.lifecycle("backgrounded", now))));
        SenderTest.assertGoldenBatch("app-lifecycle.json", dir, health, now, lines);
        session.context(JSONObject::new);
        golden(session, dir, health, "memory-usage.json", Collections.singletonList(Signals.memory(187392, 143360, "session_start", now)));
        golden(session, dir, health, "memory-pressure.json", Collections.singletonList(Signals.pressure(15, 187392, now)));
        golden(session, dir, health, "network-change.json", Collections.singletonList(Signals.network("wifi", "none", now)));
    }

    void golden(Session session, File dir, Health health, String name, List<JSONObject> events) throws Exception {
        SenderTest.assertGoldenBatch(name, dir, health, now, session.admit(events));
    }
}
