package com.nathanclaire.rum.cordova;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import org.json.JSONObject;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class ExitsTest {
    @Rule public TemporaryFolder tmp = new TemporaryFolder();
    final IdGeneratorTest.FakeStore store = new IdGeneratorTest.FakeStore();
    long now = 1793008802000L; // 2026-10-26T10:00:02.000Z

    // Newest first, as the OS returns them.
    static final Exits.Record ANR = new Exits.Record(6, 100, 0, "user request after error: Input dispatching timed out",
            51_200, 102_400, 1793008700000L, "----- pid 4242 -----\n\"main\" prio=5 tid=1 Native\n");
    static final Exits.Record SWIPED = new Exits.Record(10, 400, 0, null, 40_000, 90_000, 1793008600000L, null);

    @Test public void eachRecordOnce() throws Exception {
        assertEquals(2, Exits.harvest(Arrays.asList(ANR, SWIPED), store, now).size());
        assertEquals(0, Exits.harvest(Arrays.asList(ANR, SWIPED), store, now).size());
        Exits.Record later = new Exits.Record(4, 100, 0, "crash", 1, 1, 1793008800000L, null);
        List<JSONObject> out = Exits.harvest(Arrays.asList(later, ANR, SWIPED), store, now);
        assertEquals(1, out.size());
        assertEquals("crash", out.get(0).getJSONObject("attributes").getString("exit.reason"));
    }

    @Test public void mapsUnknownCodesAndCapsTrace() throws Exception {
        StringBuilder big = new StringBuilder();
        while (big.length() < 5000) big.append("frame\n");
        JSONObject a = Exits.harvest(Arrays.asList(new Exits.Record(99, 7, 0, null, 0, 0, 1, big.toString())), store, now)
                .get(0).getJSONObject("attributes");
        assertEquals("unknown_99", a.getString("exit.reason"));
        assertEquals("unknown_7", a.getString("exit.importance"));
        assertFalse("R15: null omitted", a.has("exit.description"));
        assertTrue(a.getString("exit.trace").endsWith("…[trace truncated]"));
    }

    @Test public void unreadableWatermarkResendsRatherThanLoses() throws Exception {
        store.values.put(Exits.KEY_WATERMARK, "garbage");
        assertEquals(2, Exits.harvest(Arrays.asList(ANR, SWIPED), store, now).size());
    }

    @Test public void goldenBatch() throws Exception {
        Health health = new Health(new File(tmp.getRoot(), "edge_rum"));
        Session session = new Session(store, health, () -> now, 1.0, () -> 0.0, () -> "session_1", () -> null);
        session.begin();
        List<String> lines = new ArrayList<>(session.admit(Exits.harvest(Arrays.asList(ANR, SWIPED), store, now)));
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
            SenderTest.assertGolden("app-exit.json", SenderTest.gunzip(server.takeRequest()));
        } finally {
            server.shutdown();
        }
    }
}
