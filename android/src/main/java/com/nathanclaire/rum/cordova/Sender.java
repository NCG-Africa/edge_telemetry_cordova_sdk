package com.nathanclaire.rum.cordova;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.LongSupplier;
import java.util.zip.GZIPOutputStream;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Spec T3, T5, T6 and wire rules R1–R4, R10, R12, R13: drains sealed segments oldest first, one
 * request in flight, each as a gzipped contract-4 envelope.
 */
final class Sender {
    static final String CONTRACT_VERSION = "4.0.0";
    static final long[] RETRY_MS = {1_000, 4_000, 16_000};
    /** Backoff of a parked segment; matches the 30 s tick that retries it (T6). */
    static final long PARK_MS = 30_000;

    interface Sleeper {
        void sleep(long ms) throws InterruptedException;
    }

    private final Outbox outbox;
    private final Health health;
    private final String sdkVersion;
    private final LongSupplier clock;
    private final Sleeper sleeper;
    private final long[] retryMs;
    private final Map<String, Long> parkedUntil = new HashMap<>();
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final AtomicBoolean pending = new AtomicBoolean();
    private volatile String apiKey;
    private volatile String endpoint;

    Sender(Outbox outbox, Health health, String sdkVersion) {
        this(outbox, health, sdkVersion, System::currentTimeMillis, Thread::sleep, RETRY_MS);
    }

    Sender(Outbox outbox, Health health, String sdkVersion, LongSupplier clock, Sleeper sleeper, long[] retryMs) {
        this.outbox = outbox;
        this.health = health;
        this.sdkVersion = sdkVersion;
        this.clock = clock;
        this.sleeper = sleeper;
        this.retryMs = retryMs;
    }

    /** Missing key or endpoint holds segments on disk until both are known (C1). */
    void configure(String apiKey, String endpoint) {
        this.apiKey = apiKey;
        this.endpoint = endpoint;
    }

    boolean configured() {
        return apiKey != null && endpoint != null;
    }

    /** Schedules a drain on the sender thread; triggers while one is queued coalesce. */
    void trigger() {
        if (pending.compareAndSet(false, true)) {
            executor.execute(() -> {
                pending.set(false);
                drain();
            });
        }
    }

    /** Sends every sealed segment not inside its park backoff; stops at the first one it parks. */
    void drain() {
        if (!configured()) return;
        for (File f : outbox.sealed()) {
            Long until = parkedUntil.get(f.getName());
            if (until != null && clock.getAsLong() < until) continue;
            try {
                if (!send(f)) return;
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }

    /** @return false when the segment was parked. */
    private boolean send(File f) throws InterruptedException {
        Outbox.Segment seg;
        try {
            seg = outbox.read(f);
        } catch (IOException e) {
            return true; // vanished (capped or deleted meanwhile)
        }
        if (seg.identity == null || seg.events.isEmpty()) {
            outbox.delete(f);
            return true;
        }
        Map<String, Long> drops = health.snapshot();
        int queueDepth = outbox.sealed().size();
        for (int attempt = 0; ; attempt++) {
            int status;
            long retryAfterMs = 0;
            try {
                byte[] body = body(seg, drops, queueDepth, clock.getAsLong()).getBytes(StandardCharsets.UTF_8);
                HttpURLConnection c = post(gzip(body));
                try {
                    status = c.getResponseCode();
                    retryAfterMs = retryAfterMs(c.getHeaderField("Retry-After"));
                } finally {
                    c.disconnect();
                }
            } catch (IOException | JSONException | RuntimeException e) {
                status = -1; // network error, or a body we can't build (retried, then parked)
            }
            if (status >= 200 && status < 300) {
                outbox.delete(f);
                health.subtract(drops);
                parkedUntil.remove(f.getName());
                return true;
            }
            if (status >= 400 && status < 500 && status != 429) {
                // R12: never retried or queued.
                outbox.delete(f);
                health.count("rejected", seg.events.size());
                parkedUntil.remove(f.getName());
                return true;
            }
            if (attempt == retryMs.length) {
                parkedUntil.put(f.getName(), clock.getAsLong() + Math.max(PARK_MS, retryAfterMs));
                return false;
            }
            long base = retryMs[attempt];
            sleeper.sleep(Math.max(base + ThreadLocalRandom.current().nextLong(base / 4 + 1), retryAfterMs));
        }
    }

    private HttpURLConnection post(byte[] gzipped) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(endpoint).openConnection();
        c.setRequestMethod("POST");
        c.setConnectTimeout(15_000);
        c.setReadTimeout(15_000);
        c.setDoOutput(true);
        c.setFixedLengthStreamingMode(gzipped.length);
        c.setRequestProperty("Content-Type", "application/json");
        c.setRequestProperty("Content-Encoding", "gzip");
        c.setRequestProperty("X-API-Key", apiKey);
        try (OutputStream out = c.getOutputStream()) {
            out.write(gzipped);
        }
        return c;
    }

    /**
     * Contract-4 envelope, closed at 8 keys (R3). Identity is the segment's frozen first line
     * (T4); `sdk` and `contract_version` are current; `timestamp` is this attempt's (R13).
     */
    private String body(Outbox.Segment seg, Map<String, Long> drops, int queueDepth, long now)
            throws JSONException {
        JSONObject identity = new JSONObject(seg.identity);
        String timestamp = rfc3339(now);
        List<String> events = seg.events;
        StringBuilder sb = new StringBuilder(256 + events.size() * 256)
                .append("{\"type\":\"telemetry_batch\",\"contract_version\":\"").append(CONTRACT_VERSION)
                .append("\",\"timestamp\":").append(JSONObject.quote(timestamp))
                .append(",\"batch_size\":").append(events.size() + (drops.isEmpty() ? 0 : 1))
                .append(",\"device_id\":").append(JSONObject.quote(identity.getString("device_id")))
                .append(",\"sdk\":{\"name\":\"cordova\",\"version\":").append(JSONObject.quote(sdkVersion))
                .append("},\"app\":").append(identity.getJSONObject("app"))
                .append(",\"events\":[");
        for (int i = 0; i < events.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append(events.get(i));
        }
        if (!drops.isEmpty()) {
            // R4: unprefixed counters, counted in batch_size, stamped at flush time.
            JSONObject attrs = new JSONObject(drops).put("queue_depth", queueDepth);
            JSONObject health = new JSONObject()
                    .put("type", "event")
                    .put("eventName", "sdk.health")
                    .put("timestamp", timestamp)
                    .put("attributes", attrs);
            sb.append(',').append(health);
        }
        return sb.append("]}").toString();
    }

    static String rfc3339(long ms) {
        SimpleDateFormat f = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        f.setTimeZone(TimeZone.getTimeZone("UTC"));
        return f.format(new Date(ms));
    }

    private static byte[] gzip(byte[] body) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(body.length / 4 + 64);
        try (GZIPOutputStream gz = new GZIPOutputStream(bytes)) {
            gz.write(body);
        }
        return bytes.toByteArray();
    }

    /** `Retry-After` in delta-seconds; HTTP-date form ignored. */
    private static long retryAfterMs(String header) {
        if (header == null) return 0;
        try {
            return Math.max(0, Long.parseLong(header.trim())) * 1000;
        } catch (NumberFormatException e) {
            return 0;
        }
    }
}
