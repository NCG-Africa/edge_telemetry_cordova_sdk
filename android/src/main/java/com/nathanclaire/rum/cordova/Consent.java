package com.nathanclaire.rum.cordova;

import java.util.Collections;
import java.util.List;

/** Spec P7: the enabled state and what `enable()`, `disable()` and `reset()` do to stored data. */
final class Consent {
    static final String KEY_ENABLED = "enabled";

    private final IdGenerator.Store store;
    private final Session session;
    private final User user;
    private final Outbox outbox;
    private final IdGenerator ids;
    private volatile boolean enabled;

    /** @param prefEnabled C1 `EdgeRumEnabled`; a persisted `enable()`/`disable()` overrides it. */
    Consent(IdGenerator.Store store, boolean prefEnabled, Session session, User user, Outbox outbox, IdGenerator ids) {
        this.store = store;
        this.session = session;
        this.user = user;
        this.outbox = outbox;
        this.ids = ids;
        String saved = null;
        try {
            saved = store.get(KEY_ENABLED);
        } catch (RuntimeException ignored) {
            // unreadable: the pref decides
        }
        enabled = saved != null ? Boolean.parseBoolean(saved) : prefEnabled;
    }

    boolean enabled() {
        return enabled;
    }

    /**
     * Persisted. Enabling begins a session (bookends returned to append); disabling forgets the
     * session and deletes the unsent outbox and the user's traits.
     */
    synchronized List<String> setEnabled(boolean on) {
        try {
            store.put(KEY_ENABLED, String.valueOf(on));
        } catch (RuntimeException ignored) {
            // applies to this process only
        }
        if (on == enabled) return Collections.emptyList();
        enabled = on;
        if (on) return session.begin();
        session.end();
        outbox.clear();
        user.clear();
        return Collections.emptyList();
    }

    /** Clears user and outbox and rotates device_id; the caller starts the new session. @return the new device_id */
    synchronized String reset() {
        outbox.clear();
        user.clear();
        return ids.rotate();
    }
}
