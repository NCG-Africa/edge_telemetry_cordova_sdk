package com.nathanclaire.rum.cordova;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import java.io.File;
import java.util.Collections;
import org.json.JSONObject;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class UserTest {
    @Rule public TemporaryFolder tmp = new TemporaryFolder();
    final IdGeneratorTest.FakeStore store = new IdGeneratorTest.FakeStore();

    @Test public void goldenBatch() throws Exception {
        long now = 1793008802000L; // 2026-10-26T10:00:02.000Z
        File dir = new File(tmp.getRoot(), "edge_rum");
        Health health = new Health(dir);
        User user = new User(store);
        Session session = new Session(store, health, () -> now, 1.0, () -> 0.0, () -> "session_1", user::id);
        session.begin();
        JSONObject update = user.identify(new JSONObject().put("id", "u1").put("name", "Ann").put("email", "ann@example.com")
                .put("phone", "+254700000000"));
        update.put("timestamp", Sender.rfc3339(now));
        SenderTest.assertGoldenBatch("user-profile-update.json", dir, health, now, session.admit(Collections.singletonList(update)));
    }

    @Test public void identifyPersistsAndEmitsProfileUpdateOnlyWhenTraitsChange() throws Exception {
        User user = new User(store);
        JSONObject update = user.identify(new JSONObject().put("id", "u1").put("name", "Ann").put("email", "a@x.io"));
        assertEquals("user.profile.update", update.getString("eventName"));
        JSONObject a = update.getJSONObject("attributes");
        assertEquals(3, a.length());
        assertEquals("u1", a.getString("user.id"));
        assertEquals("Ann", a.getString("user.name"));
        assertEquals("a@x.io", a.getString("user.email"));

        User relaunched = new User(store);
        assertEquals("u1", relaunched.id());
        assertNull("same traits: no update", relaunched.identify(new JSONObject().put("id", "u1").put("name", "Ann")));
        assertNull("id-only change: no update", relaunched.identify(new JSONObject().put("id", "u2")));
        assertEquals("u2", relaunched.id());
        JSONObject phone = relaunched.identify(new JSONObject().put("phone", "+254700000000"));
        assertEquals("+254700000000", phone.getJSONObject("attributes").getString("user.phone"));
        assertEquals("Ann", phone.getJSONObject("attributes").getString("user.name"));
    }

    @Test public void blankAndNullTraitsAreIgnored() throws Exception {
        User user = new User(store);
        assertNull(user.identify(new JSONObject().put("id", " ").put("name", JSONObject.NULL)));
        assertNull(user.id());
    }

    @Test public void clearForgetsEverything() throws Exception {
        User user = new User(store);
        user.identify(new JSONObject().put("id", "u1").put("name", "Ann"));
        user.clear();
        assertNull(user.id());
        assertNull(new User(store).id());
        assertEquals("traits forgotten: same name is a change again",
                "Ann", new User(store).identify(new JSONObject().put("name", "Ann")).getJSONObject("attributes").getString("user.name"));
    }
}
