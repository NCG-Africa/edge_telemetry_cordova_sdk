package com.nathanclaire.rum.cordova;

import static org.junit.Assume.assumeTrue;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

/**
 * Spec 2026-11-23 stable goldens, JS set: the rows `test/golden-batch.test.ts` hands to `enqueue`,
 * stamped by the session gate and sent by the real sender, dumped to `test/golden-raw/js`.
 * Skipped until vitest has written the rows (`scripts/conform.sh` runs both in order).
 */
public class JsGoldenTest {
    @Rule public TemporaryFolder tmp = new TemporaryFolder();

    @Test public void jsRowsAsGoldenBatch() throws Exception {
        File rows = new File("../test/golden-raw/js-rows.json");
        assumeTrue("run test/golden-batch.test.ts first", rows.exists());
        JSONArray a = new JSONArray(new String(Files.readAllBytes(rows.toPath()), StandardCharsets.UTF_8));
        List<JSONObject> events = new ArrayList<>();
        for (int i = 0; i < a.length(); i++) events.add(a.getJSONObject(i));
        long now = 1793008802000L; // 2026-10-26T10:00:02.000Z
        File dir = new File(tmp.getRoot(), "edge_rum");
        Health health = new Health(dir);
        Session session = new Session(new IdGeneratorTest.FakeStore(), health, () -> now, 1.0, () -> 0.0,
                () -> "session_1", () -> "u1");
        session.begin(); // its session.started bookend is native's, not part of the JS set
        JSONObject ctx = SignalsTest.deviceContext();
        session.context(() -> ctx);
        SenderTest.dumpGoldenBatch("batch.json", dir, health, now, session.admit(events), "js");
    }
}
