package com.nathanclaire.rum.cordova;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import org.json.JSONObject;
import org.junit.Test;

public class UserTest {
    final IdGeneratorTest.FakeStore store = new IdGeneratorTest.FakeStore();

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
