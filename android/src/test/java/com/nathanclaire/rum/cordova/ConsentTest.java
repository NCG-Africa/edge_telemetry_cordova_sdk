package com.nathanclaire.rum.cordova;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.util.Collections;
import org.json.JSONObject;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class ConsentTest {
    @Rule public TemporaryFolder tmp = new TemporaryFolder();
    final IdGeneratorTest.FakeStore store = new IdGeneratorTest.FakeStore();
    Outbox outbox;
    User user;
    Session session;
    IdGenerator ids;

    @Before public void setUp() {
        File dir = new File(tmp.getRoot(), "edge_rum");
        Health health = new Health(dir);
        outbox = new Outbox(dir, System::currentTimeMillis, health);
        user = new User(store);
        ids = new IdGenerator(store);
        int[] n = {0};
        session = new Session(store, health, System::currentTimeMillis, 1.0, () -> 0, () -> "session_" + ++n[0], user::id);
    }

    Consent consent(boolean pref) {
        return new Consent(store, pref, session, user, outbox, ids);
    }

    @Test public void optInModeStartsDisabledUntilEnable() {
        Consent c = consent(false);
        assertFalse(c.enabled());
        assertEquals("enable starts a session", 1, c.setEnabled(true).size());
        assertTrue(c.enabled());
        assertTrue("persisted over the pref", consent(false).enabled());
    }

    @Test public void disablePersistsOverPrefAndWipesOutboxTraitsAndSession() throws Exception {
        Consent c = consent(true);
        session.begin();
        user.identify(new JSONObject().put("id", "u1"));
        outbox.append(SenderTest.IDENTITY, Collections.singletonList("{}"));
        outbox.seal();
        outbox.append(SenderTest.IDENTITY, Collections.singletonList("{}"));

        assertTrue(c.setEnabled(false).isEmpty());
        assertFalse(c.enabled());
        outbox.seal();
        assertTrue(outbox.sealed().isEmpty());
        assertNull(new User(store).id());
        assertNull(session.id());
        assertFalse("persisted over EdgeRumEnabled=true", consent(true).enabled());
    }

    @Test public void repeatedEnableIsANoOp() {
        Consent c = consent(true);
        session.begin();
        assertTrue(c.setEnabled(true).isEmpty());
        assertEquals("session_1", session.id());
    }

    @Test public void resetRotatesDeviceIdAndClearsUserAndOutbox() throws Exception {
        Consent c = consent(true);
        String before = ids.deviceId();
        user.identify(new JSONObject().put("id", "u1"));
        outbox.append(SenderTest.IDENTITY, Collections.singletonList("{}"));

        String after = c.reset();
        assertNotEquals(before, after);
        assertEquals(after, new IdGenerator(store).deviceId());
        assertNull(user.id());
        outbox.seal();
        assertTrue(outbox.sealed().isEmpty());
        assertTrue("reset leaves enabled state alone", c.enabled());
    }
}
