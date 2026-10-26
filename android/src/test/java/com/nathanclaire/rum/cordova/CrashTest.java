package com.nathanclaire.rum.cordova;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.After;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class CrashTest {
    /** The build that crashed; the relaunch runs {@link SenderTest#IDENTITY} (1.4.2). */
    static final String CRASHED_IDENTITY = SenderTest.IDENTITY.replace("1.4.2", "1.4.1").replace("\"142\"", "\"141\"");
    static final String NDK_REPORT = "signal 11\ncode 1\nfault_addr 0\ntime_ms 1793008801500\npid 4242\ntid 4242\n"
            + "thread fixture.app\n"
            + "frame 1a2c 4f6e8a0b1c2d3e4f5a6b7c8d9e0f1a2b /data/app/~~x/com.nathanclaire.rum.fixture-y/lib/arm64/libgame.so\n"
            + "frame 9f10 - /system/lib64/libc.so\n";

    @Rule public TemporaryFolder tmp = new TemporaryFolder();
    final IdGeneratorTest.FakeStore store = new IdGeneratorTest.FakeStore();
    final Thread main = new Thread("main");
    long now = 1793008802000L; // 2026-10-26T10:00:02.000Z
    File dir;
    Health health;
    Session session;
    Crash crash;
    Outbox outbox;
    MockWebServer server = new MockWebServer();
    Thread.UncaughtExceptionHandler original;

    @Before public void setUp() throws Exception {
        original = Thread.getDefaultUncaughtExceptionHandler();
        dir = new File(tmp.getRoot(), "edge_rum");
        health = new Health(dir);
        session = new Session(store, health, () -> now, 1.0, () -> 0.0, () -> "session_1", () -> "u1");
        session.begin();
        crash = new Crash(dir, main, () -> now);
        outbox = new Outbox(dir, () -> now, health);
        server.start();
    }

    @After public void tearDown() throws Exception {
        Thread.setDefaultUncaughtExceptionHandler(original);
        server.shutdown();
    }

    static JSONObject payload(int crumbs, String screen) throws Exception {
        JSONArray b = new JSONArray();
        for (int i = 0; i < crumbs; i++) b.put(new JSONObject().put("category", "navigation").put("message", "crumb " + i));
        JSONArray events = new JSONArray();
        if (screen != null) events.put(SessionTest.event("navigation", "navigation.to_screen", screen));
        return new JSONObject().put("events", events).put("breadcrumbs", b);
    }

    static IllegalStateException fixedException() {
        IllegalStateException e = new IllegalStateException("cart is null", new NullPointerException("item"));
        e.setStackTrace(new StackTraceElement[] {
                new StackTraceElement("com.fixture.Cart", "total", "Cart.java", 42),
                new StackTraceElement("android.os.Handler", "dispatchMessage", "Handler.java", 102)});
        e.getCause().setStackTrace(new StackTraceElement[0]);
        return e;
    }

    /** The plugin's `solo()`: session gate, then a segment of its own. */
    void solo(JSONObject event, String identity) throws Exception {
        for (String line : session.admit(Collections.singletonList(event))) outbox.writeSolo(identity, line);
    }

    /** Next launch: a fresh outbox seals leftovers; drains everything; one body per batch. */
    List<String> relaunchAndSend() throws Exception {
        now += 1_000;
        Outbox outbox = new Outbox(dir, () -> now, health);
        Sender sender = new Sender(outbox, health, "1.0.0", () -> now, ms -> { }, new long[] {1});
        sender.configure("k", server.url("/").toString());
        int n = outbox.sealed().size();
        for (int i = 0; i < n; i++) server.enqueue(new MockResponse().setResponseCode(200));
        sender.drain();
        List<String> bodies = new ArrayList<>();
        for (int i = 0; i < n; i++) bodies.add(SenderTest.gunzip(server.takeRequest()));
        return bodies;
    }

    @Test public void jvmCrashIsSoloSegmentReplayedNextLaunchInItsOwnBatchWithoutHealth() throws Exception {
        crash.mirror(payload(2, "/cart"));
        outbox.append(SenderTest.IDENTITY, session.admit(Collections.singletonList(SessionTest.event("navigation"))));
        health.count("outbox_full", 3);

        solo(crash.jvm(main, fixedException()), SenderTest.IDENTITY);
        List<String> bodies = relaunchAndSend();

        assertEquals("crash batch + the open segment sealed at relaunch", 2, bodies.size());
        SenderTest.assertGolden("app-crash-jvm.json", bodies.get(0));
        JSONObject normal = new JSONObject(bodies.get(1));
        JSONArray events = normal.getJSONArray("events");
        assertEquals("sdk.health rides the normal batch", "sdk.health", events.getJSONObject(events.length() - 1).getString("eventName"));
    }

    @Test public void installJvmChainsToThePreviousHandler() throws Exception {
        List<String> order = new ArrayList<>();
        Thread.setDefaultUncaughtExceptionHandler((t, e) -> order.add("previous"));
        List<JSONObject> sunk = new ArrayList<>();
        crash.installJvm(e -> {
            order.add("sink");
            sunk.add(e);
        });
        Thread worker = new Thread("worker");
        Thread.getDefaultUncaughtExceptionHandler().uncaughtException(worker, fixedException());

        assertEquals(java.util.Arrays.asList("sink", "previous"), order);
        JSONObject a = sunk.get(0).getJSONObject("attributes");
        assertEquals("worker", a.getString("crash_thread"));
        assertFalse(a.getBoolean("crash_is_main_thread"));
    }

    @Test public void failingSinkStillChains() {
        List<String> order = new ArrayList<>();
        Thread.setDefaultUncaughtExceptionHandler((t, e) -> order.add("previous"));
        crash.installJvm(e -> {
            throw new IllegalStateException("disk full");
        });
        Thread.getDefaultUncaughtExceptionHandler().uncaughtException(main, fixedException());
        assertEquals(Collections.singletonList("previous"), order);
    }

    @Test public void breadcrumbRingKeepsLastFifty() throws Exception {
        crash.mirror(payload(40, "/a"));
        crash.mirror(payload(30, null));
        JSONArray crumbs = new JSONArray(crash.jvm(main, fixedException()).getJSONObject("attributes").getString("crash.breadcrumbs"));
        assertEquals(Crash.BREADCRUMBS, crumbs.length());
        assertEquals("crumb 20", crumbs.getJSONObject(0).getString("message"));
        assertEquals("crumb 29", crumbs.getJSONObject(49).getString("message"));
    }

    @Test public void ndkCrashReplaysNextLaunchUnderTheCrashedBuildsIdentity() throws Exception {
        crash.mirror(payload(1, "/checkout"));
        crash.saveContext(CRASHED_IDENTITY, "session_1", "u1");
        write(new File(crash.ndkReportPath()), NDK_REPORT);

        Crash next = new Crash(dir, main, () -> now);
        Crash.Pending p = next.takeNdk();
        assertEquals(CRASHED_IDENTITY, p.identity);
        assertNull("report consumed", next.takeNdk());
        outbox.writeSolo(p.identity, p.event);
        SenderTest.assertGolden("app-crash-ndk.json", relaunchAndSend().get(0));
    }

    @Test public void tornNdkReportIsDropped() throws Exception {
        crash.saveContext(CRASHED_IDENTITY, "session_1", null);
        write(new File(crash.ndkReportPath()), "sig");
        assertNull(crash.takeNdk());
        assertFalse(new File(crash.ndkReportPath()).exists());
    }

    @Test public void ndkFrameNamesAndMainThread() throws Exception {
        JSONObject a = Crash.ndk(NDK_REPORT.replace("tid 4242", "tid 4300"), new JSONObject()).getJSONObject("attributes");
        assertEquals("libgame.so+0x1a2c", a.getString("error_context"));
        assertFalse(a.getBoolean("crash_is_main_thread"));
        assertTrue(a.getString("stacktrace").startsWith("#00 pc 0000000000001a2c  /data/app/"));
    }

    @Test public void clearForgetsEverything() throws Exception {
        crash.mirror(payload(3, "/a"));
        crash.saveContext(CRASHED_IDENTITY, "session_1", null);
        write(new File(crash.ndkReportPath()), NDK_REPORT);
        crash.clear();
        assertNull(crash.takeNdk());
        JSONObject a = crash.jvm(main, fixedException()).getJSONObject("attributes");
        assertEquals("[]", a.getString("crash.breadcrumbs"));
        assertFalse(a.has("screen_name"));
    }

    @Test public void anrAndHangGoldenBatches() throws Exception {
        crash.mirror(payload(0, "/cart"));
        String stack = "at android.os.MessageQueue.nativePollOnce(Native Method)\nat com.fixture.Cart.total(Cart.java:42)\n";
        solo(crash.stall("app.hang", 2_100, stack), SenderTest.IDENTITY);
        now += 1;
        solo(crash.stall("app.anr", 5_000, stack), SenderTest.IDENTITY);
        List<String> bodies = relaunchAndSend();
        SenderTest.assertGolden("app-hang.json", bodies.get(0));
        SenderTest.assertGolden("app-anr.json", bodies.get(1));
    }

    @Test public void sampledOutSessionKeepsAnrDropsHang() throws Exception {
        store.values.clear();
        session = new Session(store, health, () -> now, 0.5, () -> 0.9, () -> "session_2", () -> null);
        session.begin();
        solo(crash.stall("app.hang", 2_000, ""), SenderTest.IDENTITY);
        solo(crash.stall("app.anr", 5_000, ""), SenderTest.IDENTITY);
        List<File> sealed = outbox.sealed();
        assertEquals(1, sealed.size());
        assertTrue(outbox.read(sealed.get(0)).events.get(0).contains("\"app.anr\""));
    }

    static void write(File f, String s) throws Exception {
        try (FileOutputStream out = new FileOutputStream(f)) {
            out.write(s.getBytes(StandardCharsets.UTF_8));
        }
    }
}
