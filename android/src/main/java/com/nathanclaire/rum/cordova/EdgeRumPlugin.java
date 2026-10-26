package com.nathanclaire.rum.cordova;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Process;
import android.os.SystemClock;
import java.io.File;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.LOG;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** Native core entry point (spec A1). Loaded at launch via onload=true. */
public class EdgeRumPlugin extends CordovaPlugin {
    private static final String TAG = "EdgeRum";
    private static final String KEY_ENABLED = "enabled";

    private Outbox outbox;
    private Sender sender;
    /** Serial: timers and every state-changing action, so a disable can't interleave an append. */
    private ScheduledExecutorService worker;
    private IdGenerator.Store prefs;
    private IdGenerator ids;
    private User user;
    private Session session;
    private volatile boolean enabled;
    private volatile CallbackContext subscriber;
    private String identity;
    private String sdkVersion;
    private final long processStartedAt =
            System.currentTimeMillis() - (SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime());

    @Override
    protected void pluginInitialize() {
        Context ctx = cordova.getContext();
        File dir = new File(ctx.getFilesDir(), "edge_rum");
        Health health = new Health(dir);
        outbox = new Outbox(dir, System::currentTimeMillis, health);
        sdkVersion = preferences.getString("EdgeRumSdkVersion", null);
        if (sdkVersion == null) {
            // plugin.xml always writes it; missing means a hand-edited config.xml.
            LOG.w(TAG, "EdgeRumSdkVersion preference missing; reinstall the plugin");
            sdkVersion = "unknown";
        }
        sender = new Sender(outbox, health, sdkVersion);
        sender.configure(pref("EDGE_RUM_API_KEY"), pref("EDGE_RUM_ENDPOINT"));
        prefs = prefsStore(ctx);
        ids = new IdGenerator(prefs);
        identity = identityLine(ctx, ids.deviceId());
        user = new User(prefs);
        SecureRandom random = new SecureRandom();
        session = new Session(prefs, health, System::currentTimeMillis, sampleRate(), random::nextDouble,
                IdGenerator::sessionId, user::id);
        // P7: a persisted enable()/disable() overrides the EdgeRumEnabled pref.
        String saved = prefs.get(KEY_ENABLED);
        enabled = saved != null ? Boolean.parseBoolean(saved) : preferences.getBoolean("EdgeRumEnabled", true);

        worker = Executors.newSingleThreadScheduledExecutor();
        if (enabled) worker.execute(() -> append(session.begin()));
        // T3: 30 s after the first event, within a second.
        worker.scheduleWithFixedDelay(outbox::sealIfDue, 1, 1, TimeUnit.SECONDS);
        // T6: 30 s retry tick for parked segments.
        worker.scheduleWithFixedDelay(sender::trigger, 30, 30, TimeUnit.SECONDS);
        sender.trigger();
    }

    /** C1 `EdgeRumSampleRate`; unparseable → NaN, which Session treats as keep-all. */
    private double sampleRate() {
        try {
            return Double.parseDouble(preferences.getString("EdgeRumSampleRate", "1.0").trim());
        } catch (NumberFormatException e) {
            return Double.NaN;
        }
    }

    /** C1 plugin variable; the plugin.xml placeholder `unset` means missing (blank is handled by Sender). */
    private String pref(String name) {
        String v = preferences.getString(name, null);
        return "unset".equals(v) ? null : v;
    }

    private static IdGenerator.Store prefsStore(Context ctx) {
        SharedPreferences prefs = ctx.getSharedPreferences("edge_rum_cordova_ids", Context.MODE_PRIVATE);
        return new IdGenerator.Store() {
            @Override public String get(String key) {
                return prefs.getString(key, null);
            }

            // A null value removes the key.
            @Override public boolean put(String key, String value) {
                return prefs.edit().putString(key, value).commit();
            }
        };
    }

    /** W3: app identity from PackageManager, no override. */
    private static String identityLine(Context ctx, String deviceId) {
        PackageManager pm = ctx.getPackageManager();
        String version = null;
        String build = null;
        try {
            PackageInfo info = pm.getPackageInfo(ctx.getPackageName(), 0);
            version = info.versionName;
            build = String.valueOf(Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : info.versionCode);
        } catch (PackageManager.NameNotFoundException ignored) {
            // Own package; unreachable in practice. Version keys stay omitted (R15).
        }
        try {
            return Sender.identityLine(ctx.getApplicationInfo().loadLabel(pm).toString(), ctx.getPackageName(),
                    version, build, deviceId);
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
    }

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext cb) throws JSONException {
        JSONObject opts = args.optJSONObject(0);
        switch (action) {
            case "getState":
                cb.success(state());
                return true;
            case "subscribe":
                subscriber = cb;
                PluginResult keep = new PluginResult(PluginResult.Status.NO_RESULT);
                keep.setKeepCallback(true);
                cb.sendPluginResult(keep);
                return true;
            case "configure":
                if (opts != null) {
                    // From init(); runtime only, never persisted (C1).
                    sender.configure(opts.optString("apiKey", null), opts.optString("endpoint", null));
                    sender.trigger();
                }
                cb.success();
                return true;
            case "enqueue":
                worker.execute(() -> enqueue(opts, cb));
                return true;
            case "identify":
                worker.execute(() -> identify(opts, cb));
                return true;
            case "clearUser":
                worker.execute(() -> {
                    user.clear();
                    cb.success();
                });
                return true;
            case "enable":
                worker.execute(() -> setEnabled(true, cb));
                return true;
            case "disable":
                worker.execute(() -> setEnabled(false, cb));
                return true;
            case "reset":
                worker.execute(() -> reset(cb));
                return true;
            default:
                return false;
        }
    }

    private JSONObject state() throws JSONException {
        return new JSONObject()
                .put("enabled", enabled)
                .put("sessionId", enabled ? session.id() : null)
                .put("userId", user.id())
                .put("sampled", session.sampled())
                .put("configured", sender.configured())
                .put("sdkVersion", sdkVersion)
                .put("deviceStartedAt", processStartedAt);
    }

    /** A2 `subscribe`: `{ type, …state }` on the kept callback. */
    private void notify(String type) {
        CallbackContext cb = subscriber;
        if (cb == null) return;
        try {
            PluginResult r = new PluginResult(PluginResult.Status.OK, state().put("type", type));
            r.setKeepCallback(true);
            cb.sendPluginResult(r);
        } catch (JSONException e) {
            LOG.w(TAG, "subscribe update failed", e);
        }
    }

    private void enqueue(JSONObject payload, CallbackContext cb) {
        JSONArray events = payload == null ? null : payload.optJSONArray("events");
        if (events == null) {
            cb.error("events missing");
            return;
        }
        // P7: opt-in mode / disabled → nothing captured or buffered.
        if (!enabled) {
            cb.success();
            return;
        }
        List<JSONObject> list = new ArrayList<>(events.length());
        for (int i = 0; i < events.length(); i++) {
            JSONObject e = events.optJSONObject(i);
            if (e != null) list.add(e);
        }
        // Not counted on failure: JS counts a failed exec as a drop (A4, T8).
        if (admit(list)) cb.success();
        else cb.error("append failed");
    }

    /** S5: every event goes through the session gate on its way into the outbox. */
    private boolean admit(List<JSONObject> events) {
        String before = session.id();
        boolean ok = append(session.admit(events));
        if (before != null && !before.equals(session.id())) notify("session");
        return ok;
    }

    private boolean append(List<String> lines) {
        if (lines.isEmpty()) return true;
        try {
            outbox.append(identity, lines);
            sender.trigger();
            return true;
        } catch (Exception e) {
            LOG.w(TAG, "append failed", e);
            return false;
        }
    }

    /** P6: persisted traits; a trait change becomes one `user.profile.update`. */
    private void identify(JSONObject traits, CallbackContext cb) {
        if (traits == null || !enabled) {
            cb.success();
            return;
        }
        try {
            JSONObject update = user.identify(traits);
            if (update != null) admit(Collections.singletonList(update));
            cb.success();
        } catch (JSONException e) {
            cb.error(String.valueOf(e.getMessage()));
        }
    }

    /** P7: persisted. Disable deletes the unsent outbox and the user's traits. */
    private void setEnabled(boolean on, CallbackContext cb) {
        prefs.put(KEY_ENABLED, String.valueOf(on));
        if (on != enabled) {
            enabled = on;
            if (on) {
                append(session.begin());
            } else {
                session.end();
                outbox.clear();
                user.clear();
            }
            notify("enabled");
        }
        cb.success();
    }

    /** P7: new device_id, new session, user and outbox cleared; enabled state untouched. */
    private void reset(CallbackContext cb) {
        outbox.clear();
        user.clear();
        identity = identityLine(cordova.getContext(), ids.rotate());
        if (enabled) {
            append(session.restart());
            notify("session");
        }
        cb.success();
    }

    @Override
    public void onPause(boolean multitasking) {
        flush();
    }

    @Override
    public void onStop() {
        flush();
    }

    @Override
    public void onResume(boolean multitasking) {
        if (worker == null) return;
        worker.execute(() -> {
            // E1: a foreground after the idle timeout starts a new session.
            List<String> bookends = enabled ? session.rotateIfIdle() : Collections.<String>emptyList();
            if (!bookends.isEmpty()) {
                append(bookends);
                notify("session");
            }
            sender.trigger();
        });
    }

    @Override
    public void onDestroy() {
        if (worker != null) worker.shutdownNow();
        if (sender != null) sender.shutdown();
    }

    /** T3: background seals the open segment and sends; off the UI thread (caps may read files). */
    private void flush() {
        if (worker == null) return;
        worker.execute(() -> {
            outbox.seal();
            sender.trigger();
        });
    }
}
