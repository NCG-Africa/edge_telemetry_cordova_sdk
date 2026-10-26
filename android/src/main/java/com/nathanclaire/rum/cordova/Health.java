package com.nathanclaire.rum.cordova;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.Scanner;
import java.util.TreeMap;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Spec T8 / R4: drop counters by reason, persisted until a batch carrying them as `sdk.health`
 * is accepted. Keys follow the iOS sibling (`events_dropped.<reason>`).
 */
final class Health {
    private final File file;
    private final Map<String, Long> dropped = new TreeMap<>();

    Health(File dir) {
        dir.mkdirs();
        file = new File(dir, "health.json");
        try {
            JSONObject saved;
            try (Scanner in = new Scanner(file, "UTF-8").useDelimiter("\\A")) {
                saved = new JSONObject(in.next());
            }
            JSONArray keys = saved.names();
            for (int i = 0; keys != null && i < keys.length(); i++) {
                dropped.put(keys.getString(i), saved.getLong(keys.getString(i)));
            }
        } catch (Exception ignored) {
            // Missing or corrupt: start from zero.
        }
    }

    synchronized void count(String reason, long n) {
        if (n <= 0) return;
        String key = "events_dropped." + reason;
        Long prev = dropped.get(key);
        dropped.put(key, (prev == null ? 0 : prev) + n);
        persist();
    }

    synchronized Map<String, Long> snapshot() {
        return new TreeMap<>(dropped);
    }

    /** Removes counts a delivered batch carried; drops counted since stay. */
    synchronized void subtract(Map<String, Long> sent) {
        if (sent.isEmpty()) return;
        for (Map.Entry<String, Long> e : sent.entrySet()) {
            Long cur = dropped.get(e.getKey());
            if (cur == null) continue;
            long left = cur - e.getValue();
            if (left > 0) dropped.put(e.getKey(), left);
            else dropped.remove(e.getKey());
        }
        persist();
    }

    private void persist() {
        File tmp = new File(file.getPath() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            out.write(new JSONObject(dropped).toString().getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            return;
        }
        tmp.renameTo(file);
    }
}
