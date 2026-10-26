package com.nathanclaire.rum.cordova;

import java.security.SecureRandom;
import java.util.UUID;

/**
 * Spec W4 / R9: port of `edge_telemetry_android` `IdGenerator` (device and session ids only).
 * Never throws: device_id is required on every batch.
 */
final class IdGenerator {
    /** The SharedPreferences calls the native core needs (ids, session, user, consent); either may throw. */
    interface Store {
        String get(String key);

        /** A null value removes the key. */
        boolean put(String key, String value);
    }

    static final String KEY_DEVICE_ID = "device_id";
    static final String KEY_FALLBACK_DEVICE_ID = "device_id_fallback";
    private static final SecureRandom RANDOM = new SecureRandom();

    private final Store store;
    // Set once the primary id has failed; pins the fallback for this process so the id is stable.
    private volatile String pinnedFallbackId;

    IdGenerator(Store store) {
        this.store = store;
    }

    synchronized String deviceId() {
        if (pinnedFallbackId != null) return pinnedFallbackId;
        try {
            // A persisted fallback wins over the primary slot, so a transient primary failure
            // can't make device_id flip between processes.
            String id = store.get(KEY_FALLBACK_DEVICE_ID);
            if (id == null) id = store.get(KEY_DEVICE_ID);
            if (id == null) {
                id = generate("device");
                store.put(KEY_DEVICE_ID, id);
            }
            return id;
        } catch (RuntimeException e) {
            return fallbackId();
        }
    }

    /** P7 `reset()`: a new device_id, replacing any fallback; in-memory if storage fails. */
    synchronized String rotate() {
        String id = generate("device");
        try {
            if (store.put(KEY_DEVICE_ID, id) && store.put(KEY_FALLBACK_DEVICE_ID, null)) {
                pinnedFallbackId = null;
                return id;
            }
        } catch (RuntimeException ignored) {
            // falls through to pinning
        }
        pinnedFallbackId = id;
        return id;
    }

    // R9: a random UUIDv4 persisted once under its own key; if storage fails too, in-memory for
    // this process.
    private String fallbackId() {
        String id;
        try {
            id = store.get(KEY_FALLBACK_DEVICE_ID);
            if (id == null) {
                id = UUID.randomUUID().toString();
                if (!store.put(KEY_FALLBACK_DEVICE_ID, id)) id = UUID.randomUUID().toString();
            }
        } catch (RuntimeException e) {
            id = UUID.randomUUID().toString();
        }
        pinnedFallbackId = id;
        return id;
    }

    static String sessionId() {
        return generate("session");
    }

    private static String generate(String kind) {
        byte[] bytes = new byte[8];
        RANDOM.nextBytes(bytes);
        StringBuilder sb = new StringBuilder(kind).append('_').append(System.currentTimeMillis()).append('_');
        for (byte b : bytes) {
            sb.append(Character.forDigit((b >> 4) & 0xF, 16)).append(Character.forDigit(b & 0xF, 16));
        }
        return sb.append("_android").toString();
    }
}
