package com.nathanclaire.rum.cordova;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.function.LongSupplier;

/**
 * Spec T2–T4, T7: append-only NDJSON segments. The open segment's first line is the identity
 * frozen for the whole segment (T4); every later line is one event. One sealed segment = one batch.
 */
final class Outbox {
    static final int SEAL_EVENTS = 50;
    static final long SEAL_AGE_MS = 30_000;
    static final long MAX_BYTES = 5L * 1024 * 1024;
    static final int MAX_SEGMENTS = 200;
    static final long MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000;

    private static final String SEALED_SUFFIX = ".ndjson";

    static final class Segment {
        final String identity;
        final List<String> events;

        Segment(String identity, List<String> events) {
            this.identity = identity;
            this.events = events;
        }
    }

    private final File dir;
    private final File open;
    private final LongSupplier clock;
    private final Health health;
    private int openCount;
    private long openedAt;
    private int seq;

    Outbox(File dir, LongSupplier clock, Health health) {
        this.dir = dir;
        this.open = new File(dir, "open.ndjson.part");
        this.clock = clock;
        this.health = health;
        dir.mkdirs();
        // A previous process's open segment is sealed now and sent this launch (T3).
        seal();
    }

    /** Appends one hand-off and flushes it to the OS; seals every {@link #SEAL_EVENTS} events. */
    synchronized void append(String identity, List<String> events) throws IOException {
        int i = 0;
        while (i < events.size()) {
            int n = Math.min(events.size() - i, SEAL_EVENTS - openCount);
            write(identity, events.subList(i, i + n));
            i += n;
            if (openCount >= SEAL_EVENTS) seal();
        }
    }

    private void write(String identity, List<String> events) throws IOException {
        StringBuilder sb = new StringBuilder();
        if (!open.exists()) {
            sb.append(identity).append('\n');
            openCount = 0;
            openedAt = clock.getAsLong();
        }
        for (String e : events) sb.append(e).append('\n');
        try (FileOutputStream out = new FileOutputStream(open, true)) {
            out.write(sb.toString().getBytes(StandardCharsets.UTF_8));
        }
        openCount += events.size();
    }

    /** 30 s after the open segment's first event (T3). */
    synchronized void sealIfDue() {
        if (open.exists() && clock.getAsLong() - openedAt >= SEAL_AGE_MS) seal();
    }

    synchronized void seal() {
        if (open.exists()) {
            // Name = seal time + per-process sequence, so name order is age order.
            String name = String.format(Locale.US, "%013d-%06d%s", clock.getAsLong(), seq++, SEALED_SUFFIX);
            open.renameTo(new File(dir, name));
            openCount = 0;
        }
        enforceCaps();
    }

    /** Sealed segments, oldest first. */
    List<File> sealed() {
        File[] files = dir.listFiles((d, name) -> name.endsWith(SEALED_SUFFIX) && name.length() > 13);
        if (files == null) return Collections.emptyList();
        Arrays.sort(files);
        return new ArrayList<>(Arrays.asList(files));
    }

    /** Reads a segment; a torn trailing line (no newline, e.g. killed mid-write) is discarded. */
    Segment read(File f) throws IOException {
        String text = new String(readAll(f), StandardCharsets.UTF_8);
        int end = text.lastIndexOf('\n');
        List<String> lines = new ArrayList<>();
        int start = 0;
        while (start <= end) {
            int nl = text.indexOf('\n', start);
            if (nl > start) lines.add(text.substring(start, nl));
            start = nl + 1;
        }
        if (lines.isEmpty()) return new Segment(null, Collections.<String>emptyList());
        return new Segment(lines.get(0), lines.subList(1, lines.size()));
    }

    void delete(File f) {
        f.delete();
    }

    /** T7: over 5 MB or 200 segments → drop oldest; older than 7 days → drop. Counted (T8). */
    private void enforceCaps() {
        List<File> files = sealed();
        long total = 0;
        for (File f : files) total += f.length();
        int count = files.size();
        long now = clock.getAsLong();
        for (File f : files) {
            boolean expired = now - sealedAt(f) > MAX_AGE_MS;
            if (!expired && total <= MAX_BYTES && count <= MAX_SEGMENTS) break;
            int events;
            try {
                events = read(f).events.size();
            } catch (IOException e) {
                events = 0;
            }
            total -= f.length();
            count--;
            f.delete();
            health.count(expired ? "expired" : "outbox_full", events);
        }
    }

    private static long sealedAt(File f) {
        try {
            return Long.parseLong(f.getName().substring(0, 13));
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    static byte[] readAll(File f) throws IOException {
        try (InputStream in = new FileInputStream(f)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            for (int n; (n = in.read(buf)) != -1; ) out.write(buf, 0, n);
            return out.toByteArray();
        }
    }
}
