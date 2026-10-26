package com.nathanclaire.rum.cordova;

import android.content.Context;
import android.content.SharedPreferences;
import java.security.SecureRandom;
import java.util.UUID;

/**
 * Spec W4 / R9: port of `edge_telemetry_android` `IdGenerator` (device and session ids only).
 * Never throws: device_id is required on every batch.
 */
final class IdGenerator {
    private static final String PREFS_NAME = "edge_rum_cordova_ids";
    private static final String KEY_DEVICE_ID = "device_id";
    private static final String KEY_FALLBACK_DEVICE_ID = "device_id_fallback";
    private static final SecureRandom RANDOM = new SecureRandom();

    private final SharedPreferences prefs;
    // Set once the primary id has failed; pins the fallback for this process so the id is stable.
    private volatile String pinnedFallbackId;

    IdGenerator(Context context) {
        prefs = context.getApplicationContext().getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
    }

    synchronized String deviceId() {
        if (pinnedFallbackId != null) return pinnedFallbackId;
        try {
            // A persisted fallback wins over the primary slot, so a transient primary failure
            // can't make device_id flip between processes.
            String id = prefs.getString(KEY_FALLBACK_DEVICE_ID, null);
            if (id == null) id = prefs.getString(KEY_DEVICE_ID, null);
            if (id == null) {
                id = generate("device");
                prefs.edit().putString(KEY_DEVICE_ID, id).apply();
            }
            return id;
        } catch (RuntimeException e) {
            return fallbackId();
        }
    }

    // R9: a random UUIDv4 persisted once under its own key; if storage fails too, in-memory for
    // this process.
    private String fallbackId() {
        String id;
        try {
            id = prefs.getString(KEY_FALLBACK_DEVICE_ID, null);
            if (id == null) {
                id = UUID.randomUUID().toString();
                if (!prefs.edit().putString(KEY_FALLBACK_DEVICE_ID, id).commit()) id = UUID.randomUUID().toString();
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
