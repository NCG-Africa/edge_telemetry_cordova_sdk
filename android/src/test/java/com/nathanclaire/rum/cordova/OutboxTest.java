package com.nathanclaire.rum.cordova;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class OutboxTest {
    static final String ID_V1 = "{\"app\":{\"package_name\":\"com.x\",\"platform\":\"android\",\"version\":\"1.0\"},\"device_id\":\"d1\"}";
    static final String ID_V2 = "{\"app\":{\"package_name\":\"com.x\",\"platform\":\"android\",\"version\":\"2.0\"},\"device_id\":\"d1\"}";

    @Rule public TemporaryFolder tmp = new TemporaryFolder();
    long now = 1_700_000_000_000L;
    File dir;
    Health health;
    Outbox outbox;

    @Before public void setUp() {
        dir = new File(tmp.getRoot(), "edge_rum");
        health = new Health(dir);
        outbox = new Outbox(dir, () -> now, health);
    }

    static List<String> events(int n) {
        List<String> out = new ArrayList<>();
        for (int i = 0; i < n; i++) out.add("{\"type\":\"event\",\"eventName\":\"e" + i + "\"}");
        return out;
    }

    @Test public void sealsAtFiftyEventsSplittingLargeHandOffs() throws Exception {
        outbox.append(ID_V1, events(120));
        List<File> sealed = outbox.sealed();
        assertEquals(2, sealed.size());
        assertEquals(50, outbox.read(sealed.get(0)).events.size());
        assertEquals(50, outbox.read(sealed.get(1)).events.size());
        outbox.seal();
        assertEquals(20, outbox.read(outbox.sealed().get(2)).events.size());
    }

    @Test public void sealsThirtySecondsAfterFirstEvent() throws Exception {
        outbox.append(ID_V1, events(1));
        now += 29_999;
        outbox.sealIfDue();
        assertTrue(outbox.sealed().isEmpty());
        now += 1;
        outbox.sealIfDue();
        assertEquals(1, outbox.sealed().size());
    }

    @Test public void nextLaunchSealsLeftoversAndKeepsOrder() throws Exception {
        outbox.append(ID_V1, events(3));
        outbox.seal();
        now += 10;
        outbox.append(ID_V1, events(2));
        Outbox relaunched = new Outbox(dir, () -> now + 1, health);
        List<File> sealed = relaunched.sealed();
        assertEquals(2, sealed.size());
        assertEquals(3, relaunched.read(sealed.get(0)).events.size());
        assertEquals(2, relaunched.read(sealed.get(1)).events.size());
    }

    @Test public void identityIsFrozenInTheFirstLine() throws Exception {
        outbox.append(ID_V1, events(1));
        outbox.append(ID_V2, events(1));
        outbox.seal();
        Outbox.Segment seg = outbox.read(outbox.sealed().get(0));
        assertEquals(ID_V1, seg.identity);
        assertEquals(2, seg.events.size());
    }

    @Test public void tornTrailingLineIsDiscarded() throws Exception {
        outbox.append(ID_V1, events(2));
        try (FileOutputStream out = new FileOutputStream(new File(dir, "open.ndjson.part"), true)) {
            out.write("{\"type\":\"ev".getBytes(StandardCharsets.UTF_8));
        }
        Outbox relaunched = new Outbox(dir, () -> now, health);
        assertEquals(events(2), relaunched.read(relaunched.sealed().get(0)).events);
    }

    @Test public void dropsSegmentsOlderThanSevenDays() throws Exception {
        outbox.append(ID_V1, events(4));
        outbox.seal();
        now += Outbox.MAX_AGE_MS + 1;
        outbox.append(ID_V1, events(1));
        outbox.seal();
        assertEquals(1, outbox.sealed().size());
        assertEquals(Collections.singletonMap("events_dropped.expired", 4L), health.snapshot());
    }

    @Test public void capsSkipTheSegmentBeingSent() throws Exception {
        outbox.append(ID_V1, events(4));
        outbox.seal();
        File inFlight = outbox.sealed().get(0);
        outbox.sending(inFlight);
        now += Outbox.MAX_AGE_MS + 1;
        outbox.seal();
        assertTrue(inFlight.exists());
        assertEquals(Collections.emptyMap(), health.snapshot());
    }

    @Test public void segmentCountCapDropsOldest() throws Exception {
        for (int i = 0; i < Outbox.MAX_SEGMENTS + 2; i++) {
            now++;
            outbox.append(ID_V1, Arrays.asList("{\"n\":" + i + "}"));
            outbox.seal();
        }
        List<File> sealed = outbox.sealed();
        assertEquals(Outbox.MAX_SEGMENTS, sealed.size());
        assertEquals("{\"n\":2}", outbox.read(sealed.get(0)).events.get(0));
        assertEquals(Collections.singletonMap("events_dropped.outbox_full", 2L), health.snapshot());
    }

    @Test public void byteCapDropsOldest() throws Exception {
        StringBuilder big = new StringBuilder("{\"pad\":\"");
        for (int i = 0; i < 1024 * 1024; i++) big.append('x');
        String event = big.append("\"}").toString();
        for (int i = 0; i < 6; i++) {
            now++;
            outbox.append(ID_V1, Arrays.asList(event));
            outbox.seal();
        }
        assertEquals(4, outbox.sealed().size());
        assertEquals(Collections.singletonMap("events_dropped.outbox_full", 2L), health.snapshot());
    }

    @Test public void healthSurvivesRelaunchAndSubtractsWhatWasSent() {
        health.count("expired", 3);
        Health reloaded = new Health(dir);
        assertEquals(Collections.singletonMap("events_dropped.expired", 3L), reloaded.snapshot());
        reloaded.count("expired", 2);
        reloaded.subtract(Collections.singletonMap("events_dropped.expired", 3L));
        assertEquals(Collections.singletonMap("events_dropped.expired", 2L), new Health(dir).snapshot());
    }
}
