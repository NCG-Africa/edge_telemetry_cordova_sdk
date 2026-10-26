package com.nathanclaire.rum.cordova;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Scanner;
import java.util.concurrent.TimeUnit;
import java.util.zip.GZIPInputStream;
import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import okhttp3.mockwebserver.RecordedRequest;
import okhttp3.mockwebserver.SocketPolicy;
import org.json.JSONObject;
import org.junit.After;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class SenderTest {
    static final String IDENTITY = "{\"app\":{\"name\":\"Fixture\",\"package_name\":\"com.nathanclaire.rum.fixture\","
            + "\"platform\":\"android\",\"version\":\"1.4.2\",\"build_number\":\"142\"},\"device_id\":\"device_1700000000000_0123456789abcdef_android\"}";
    static final List<String> EVENTS = Arrays.asList(
            "{\"type\":\"event\",\"eventName\":\"navigation\",\"timestamp\":\"2026-10-26T10:00:00.000Z\",\"attributes\":{\"navigation.to_screen\":\"/home\"}}",
            "{\"type\":\"metric\",\"metricName\":\"LCP\",\"value\":812.5,\"timestamp\":\"2026-10-26T10:00:01.000Z\",\"attributes\":{}}");

    @Rule public TemporaryFolder tmp = new TemporaryFolder();
    MockWebServer server = new MockWebServer();
    long now = 1793008802000L; // 2026-10-26T10:00:02.000Z
    final List<Long> sleeps = new ArrayList<>();
    Health health;
    Outbox outbox;
    Sender sender;

    @Before public void setUp() throws Exception {
        server.start();
        File dir = new File(tmp.getRoot(), "edge_rum");
        health = new Health(dir);
        outbox = new Outbox(dir, () -> now, health);
        sender = new Sender(outbox, health, "1.0.0", () -> now, ms -> { sleeps.add(ms); now += ms; }, new long[] {1000, 4000, 16000});
        sender.configure("edge_key_secret", server.url("/telemetry").toString());
    }

    @After public void tearDown() throws Exception {
        server.shutdown();
    }

    void sealedBatch() throws Exception {
        outbox.append(IDENTITY, EVENTS);
        outbox.seal();
    }

    static String gunzip(RecordedRequest req) throws Exception {
        try (InputStream in = new GZIPInputStream(req.getBody().inputStream());
             Scanner s = new Scanner(in, "UTF-8").useDelimiter("\\A")) {
            return s.hasNext() ? s.next() : "";
        }
    }

    static JSONObject golden(String name) throws Exception {
        try (InputStream in = SenderTest.class.getResourceAsStream("/golden/" + name);
             Scanner s = new Scanner(in, "UTF-8").useDelimiter("\\A")) {
            return new JSONObject(s.next());
        }
    }

    static void assertGolden(String name, String body) throws Exception {
        // Key order is part of the snapshot: the envelope is written in a fixed order.
        assertEquals(name + " drifted", golden(name).toString(2), new JSONObject(body).toString(2));
    }

    @Test public void postsGzippedContractFourEnvelopeMatchingGolden() throws Exception {
        sealedBatch();
        server.enqueue(new MockResponse().setResponseCode(202));
        sender.drain();

        RecordedRequest req = server.takeRequest();
        assertEquals("POST", req.getMethod());
        assertEquals("/telemetry", req.getPath());
        assertEquals("gzip", req.getHeader("Content-Encoding"));
        assertEquals("application/json", req.getHeader("Content-Type"));
        assertEquals("edge_key_secret", req.getHeader("X-API-Key"));
        assertGolden("batch.json", gunzip(req));
        assertTrue(outbox.sealed().isEmpty());
    }

    @Test public void appendsSdkHealthWithDropCountsMatchingGolden() throws Exception {
        health.count("outbox_full", 7);
        health.count("rejected", 2);
        sealedBatch();
        server.enqueue(new MockResponse().setResponseCode(200));
        sender.drain();

        assertGolden("sdk-health.json", gunzip(server.takeRequest()));
        assertEquals(Collections.emptyMap(), health.snapshot());
    }

    @Test public void restampsTimestampPerAttempt() throws Exception {
        sealedBatch();
        server.enqueue(new MockResponse().setResponseCode(503));
        server.enqueue(new MockResponse().setResponseCode(200));
        sender.drain();

        assertEquals("2026-10-26T10:00:02.000Z", new JSONObject(gunzip(server.takeRequest())).getString("timestamp"));
        String second = new JSONObject(gunzip(server.takeRequest())).getString("timestamp");
        assertTrue(second, second.compareTo("2026-10-26T10:00:03.000Z") >= 0);
    }

    @Test public void retriesThreeTimesWithBackoffThenParks() throws Exception {
        sealedBatch();
        for (int i = 0; i < 4; i++) server.enqueue(new MockResponse().setResponseCode(500));
        sender.drain();

        assertEquals(4, server.getRequestCount());
        assertEquals(3, sleeps.size());
        assertTrue(sleeps.get(0) >= 1000 && sleeps.get(0) <= 1250);
        assertTrue(sleeps.get(1) >= 4000 && sleeps.get(1) <= 5000);
        assertTrue(sleeps.get(2) >= 16000 && sleeps.get(2) <= 20000);
        assertEquals(1, outbox.sealed().size());

        // Parked: the next trigger inside the backoff does not resend it.
        sender.drain();
        assertEquals(4, server.getRequestCount());

        now += Sender.PARK_MS;
        server.enqueue(new MockResponse().setResponseCode(200));
        sender.drain();
        assertEquals(5, server.getRequestCount());
        assertTrue(outbox.sealed().isEmpty());
    }

    @Test public void parkedSegmentDoesNotBlockNewerOnes() throws Exception {
        sealedBatch();
        for (int i = 0; i < 4; i++) server.enqueue(new MockResponse().setResponseCode(429));
        sender.drain();
        now += 1;
        sealedBatch();
        server.enqueue(new MockResponse().setResponseCode(200));
        sender.drain();

        assertEquals(5, server.getRequestCount());
        assertEquals(1, outbox.sealed().size());
    }

    @Test public void honoursRetryAfter() throws Exception {
        sealedBatch();
        server.enqueue(new MockResponse().setResponseCode(429).setHeader("Retry-After", "30"));
        server.enqueue(new MockResponse().setResponseCode(200));
        sender.drain();
        assertEquals(Collections.singletonList(30_000L), sleeps);
    }

    @Test public void networkErrorIsRetried() throws Exception {
        sealedBatch();
        server.enqueue(new MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START));
        server.enqueue(new MockResponse().setResponseCode(200));
        sender.drain();
        assertEquals(1, sleeps.size());
        assertTrue(outbox.sealed().isEmpty());
    }

    @Test public void otherFourXxDeletesAndCounts() throws Exception {
        sealedBatch();
        server.enqueue(new MockResponse().setResponseCode(400));
        sender.drain();

        assertEquals(1, server.getRequestCount());
        assertTrue(sleeps.isEmpty());
        assertTrue(outbox.sealed().isEmpty());
        assertEquals(Collections.singletonMap("events_dropped.rejected", 2L), health.snapshot());
    }

    @Test public void sendsOldestFirst() throws Exception {
        outbox.append(IDENTITY, Collections.singletonList("{\"n\":1}"));
        outbox.seal();
        now += 1;
        outbox.append(IDENTITY, Collections.singletonList("{\"n\":2}"));
        outbox.seal();
        server.enqueue(new MockResponse().setResponseCode(200));
        server.enqueue(new MockResponse().setResponseCode(200));
        sender.drain();

        assertEquals(1, new JSONObject(gunzip(server.takeRequest())).getJSONArray("events").getJSONObject(0).getInt("n"));
        assertEquals(2, new JSONObject(gunzip(server.takeRequest())).getJSONArray("events").getJSONObject(0).getInt("n"));
    }

    @Test public void holdsSegmentsUntilConfigured() throws Exception {
        sender.configure(null, null);
        sealedBatch();
        sender.drain();
        assertNull(server.takeRequest(100, TimeUnit.MILLISECONDS));
        assertEquals(1, outbox.sealed().size());
    }

    @Test public void triggerRunsOffTheCallerThread() throws Exception {
        sealedBatch();
        server.enqueue(new MockResponse().setResponseCode(200));
        sender.trigger();
        assertNotNull(server.takeRequest(5, TimeUnit.SECONDS));
    }
}
