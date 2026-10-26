package com.nathanclaire.rum.cordova;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertTrue;

import java.util.HashMap;
import java.util.Map;
import org.junit.Test;

public class IdGeneratorTest {
    /** In-memory SharedPreferences stand-in; flags simulate storage failures. */
    static final class FakeStore implements IdGenerator.Store {
        final Map<String, String> values = new HashMap<>();
        boolean failPrimaryRead;
        boolean failAll;

        @Override public String get(String key) {
            if (failAll || (failPrimaryRead && key.equals(IdGenerator.KEY_DEVICE_ID))) throw new IllegalStateException();
            return values.get(key);
        }

        @Override public boolean put(String key, String value) {
            if (failAll) throw new IllegalStateException();
            values.put(key, value);
            return true;
        }
    }

    @Test public void generatesOncePersistsAndReuses() {
        FakeStore store = new FakeStore();
        String id = new IdGenerator(store).deviceId();
        assertTrue(id, id.matches("device_\\d+_[0-9a-f]{16}_android"));
        assertEquals(id, new IdGenerator(store).deviceId());
    }

    @Test public void primaryFailureFallsBackToPersistedUuidThatWinsLater() {
        FakeStore store = new FakeStore();
        store.values.put(IdGenerator.KEY_DEVICE_ID, "device_primary");
        store.failPrimaryRead = true;
        String fallback = new IdGenerator(store).deviceId();
        assertTrue(fallback, fallback.matches("[0-9a-f-]{36}"));

        // Next process: primary readable again, but the persisted fallback wins (no flip).
        store.failPrimaryRead = false;
        assertEquals(fallback, new IdGenerator(store).deviceId());
    }

    @Test public void brokenStorageUsesInMemoryIdPinnedForTheProcess() {
        FakeStore store = new FakeStore();
        store.failAll = true;
        IdGenerator ids = new IdGenerator(store);
        String id = ids.deviceId();
        assertEquals(id, ids.deviceId());
        assertNotEquals(id, new IdGenerator(store).deviceId());
    }

    @Test public void sessionIdFormat() {
        assertTrue(IdGenerator.sessionId().matches("session_\\d+_[0-9a-f]{16}_android"));
    }

    @Test public void rotateReplacesTheIdEvenAfterFallback() {
        FakeStore store = new FakeStore();
        store.values.put(IdGenerator.KEY_FALLBACK_DEVICE_ID, "fallback");
        IdGenerator ids = new IdGenerator(store);
        assertEquals("fallback", ids.deviceId());
        String rotated = ids.rotate();
        assertNotEquals("fallback", rotated);
        assertEquals(rotated, ids.deviceId());
        assertEquals(rotated, new IdGenerator(store).deviceId());
    }

    @Test public void rotateWithBrokenStorageStillRotatesForTheProcess() {
        FakeStore store = new FakeStore();
        store.failAll = true;
        IdGenerator ids = new IdGenerator(store);
        String before = ids.deviceId();
        String rotated = ids.rotate();
        assertNotEquals(before, rotated);
        assertEquals(rotated, ids.deviceId());
    }
}
