package com.nathanclaire.rum.cordova;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Process;
import android.os.SystemClock;
import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.LOG;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** Native core entry point (spec A1). Loaded at launch via onload=true. */
public class EdgeRumPlugin extends CordovaPlugin {
    private static final String TAG = "EdgeRum";

    private Outbox outbox;
    private Sender sender;
    private ScheduledExecutorService ticker;
    private String identity;
    private String apiKey;
    private String endpoint;
    private String sdkVersion;
    // ponytail: one id per process until session rotation lands (spec E1, issue 03).
    private final String sessionId = IdGenerator.sessionId();
    private final long processStartedAt =
            System.currentTimeMillis() - (SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime());

    @Override
    protected void pluginInitialize() {
        Context ctx = cordova.getContext();
        File dir = new File(ctx.getFilesDir(), "edge_rum");
        Health health = new Health(dir);
        outbox = new Outbox(dir, System::currentTimeMillis, health);
        sdkVersion = preferences.getString("EdgeRumSdkVersion", "");
        sender = new Sender(outbox, health, sdkVersion);
        apiKey = pref("EDGE_RUM_API_KEY");
        endpoint = pref("EDGE_RUM_ENDPOINT");
        sender.configure(apiKey, endpoint);
        identity = identity(ctx, new IdGenerator(ctx).deviceId());

        // T3 30 s seal + T6 park retry tick.
        ticker = Executors.newSingleThreadScheduledExecutor();
        ticker.scheduleWithFixedDelay(() -> {
            outbox.sealIfDue();
            sender.trigger();
        }, 30, 30, TimeUnit.SECONDS);
        sender.trigger();
    }

    /** C1 plugin variable; the plugin.xml placeholder `unset` (or blank) means missing. */
    private String pref(String name) {
        String v = preferences.getString(name, null);
        return v == null || v.trim().isEmpty() || v.equals("unset") ? null : v.trim();
    }

    /** W3 + T4: the identity line frozen into each segment. Unknown values omitted (R15). */
    private static String identity(Context ctx, String deviceId) {
        JSONObject app = new JSONObject();
        try {
            PackageManager pm = ctx.getPackageManager();
            app.put("name", ctx.getApplicationInfo().loadLabel(pm).toString());
            app.put("package_name", ctx.getPackageName());
            app.put("platform", "android");
            try {
                PackageInfo info = pm.getPackageInfo(ctx.getPackageName(), 0);
                app.put("version", info.versionName);
                long code = Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : info.versionCode;
                app.put("build_number", String.valueOf(code));
            } catch (PackageManager.NameNotFoundException ignored) {
                // Own package; unreachable in practice. Version keys stay omitted.
            }
            return new JSONObject().put("app", app).put("device_id", deviceId).toString();
        } catch (JSONException e) {
            throw new IllegalStateException(e);
        }
    }

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext cb) throws JSONException {
        switch (action) {
            case "getState":
                cb.success(new JSONObject()
                        .put("enabled", preferences.getBoolean("EdgeRumEnabled", true))
                        .put("sessionId", sessionId)
                        .put("sampled", true)
                        .put("configured", sender.configured())
                        .put("sdkVersion", sdkVersion)
                        .put("deviceStartedAt", processStartedAt));
                return true;
            case "enqueue":
                JSONObject payload = args.optJSONObject(0);
                cordova.getThreadPool().execute(() -> enqueue(payload, cb));
                return true;
            case "configure":
                JSONObject opts = args.optJSONObject(0);
                if (opts != null) {
                    // From init(); runtime only, never persisted (C1).
                    String k = opts.optString("apiKey", "").trim();
                    String e = opts.optString("endpoint", "").trim();
                    if (!k.isEmpty()) apiKey = k;
                    if (!e.isEmpty()) endpoint = e;
                    sender.configure(apiKey, endpoint);
                    sender.trigger();
                }
                cb.success();
                return true;
            default:
                return false;
        }
    }

    private void enqueue(JSONObject payload, CallbackContext cb) {
        JSONArray events = payload == null ? null : payload.optJSONArray("events");
        if (events == null) {
            cb.error("events missing");
            return;
        }
        List<String> lines = new ArrayList<>(events.length());
        for (int i = 0; i < events.length(); i++) {
            JSONObject e = events.optJSONObject(i);
            if (e != null) lines.add(e.toString());
        }
        try {
            outbox.append(identity, lines);
            cb.success();
        } catch (Exception e) {
            LOG.w(TAG, "enqueue failed", e);
            cb.error(String.valueOf(e.getMessage()));
        }
        sender.trigger();
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
        sender.trigger();
    }

    @Override
    public void onDestroy() {
        if (ticker != null) ticker.shutdownNow();
    }

    /** T3: background seals the open segment and sends. */
    private void flush() {
        if (outbox == null) return;
        outbox.seal();
        sender.trigger();
    }
}
