package com.nathanclaire.rum.cordova;

import org.json.JSONException;
import org.json.JSONObject;

/** Spec P6: `identify()` traits, persisted until `clearUser()`. */
final class User {
    static final String KEY = "user";
    private static final String[] TRAITS = {"name", "email", "phone"};

    private final IdGenerator.Store store;
    private JSONObject user;

    User(IdGenerator.Store store) {
        this.store = store;
        try {
            String saved = store.get(KEY);
            user = saved == null ? new JSONObject() : new JSONObject(saved);
        } catch (JSONException | RuntimeException e) {
            user = new JSONObject();
        }
    }

    synchronized String id() {
        return user.has("id") ? user.optString("id") : null;
    }

    /**
     * Merges the given non-blank keys. Returns one `user.profile.update` event when name, email
     * or phone changed, else null.
     */
    synchronized JSONObject identify(JSONObject given) throws JSONException {
        boolean traitsChanged = false;
        for (String k : new String[] {"id", "name", "email", "phone"}) {
            Object v = given.opt(k);
            if (!(v instanceof String) || ((String) v).trim().isEmpty()) continue;
            if (!k.equals("id") && !v.equals(user.opt(k))) traitsChanged = true;
            user.put(k, v);
        }
        try {
            store.put(KEY, user.toString());
        } catch (RuntimeException ignored) {
            // kept in memory for this process
        }
        if (!traitsChanged) return null;
        JSONObject attrs = new JSONObject();
        if (user.has("id")) attrs.put("user.id", user.get("id"));
        for (String k : TRAITS) if (user.has(k)) attrs.put("user." + k, user.get(k));
        return new JSONObject()
                .put("type", "event")
                .put("eventName", "user.profile.update")
                .put("timestamp", Sender.rfc3339(System.currentTimeMillis()))
                .put("attributes", attrs);
    }

    synchronized void clear() {
        user = new JSONObject();
        try {
            store.put(KEY, null);
        } catch (RuntimeException ignored) {
            // forgotten in memory; a stale copy may return next launch
        }
    }
}
