package com.nathanclaire.rum.example;

import android.content.Intent;
import android.webkit.WebView;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.json.JSONArray;

/** Example app only: native scenarios + the `scenario` intent extra (`am start … --es scenario <name>`). */
public class ExampleScenarios extends CordovaPlugin {
    // listen (WebView thread) and deliver (UI thread) synchronize on this plugin.
    private boolean listening;
    private String pending;

    @Override
    protected synchronized void pluginInitialize() {
        pending = cordova.getActivity().getIntent().getStringExtra("scenario");
    }

    @Override
    public void onNewIntent(Intent intent) {
        String s = intent.getStringExtra("scenario");
        if (s != null) deliver(s);
    }

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext cb) {
        switch (action) {
            case "listen":
                synchronized (this) {
                    listening = true;
                    cb.success(pending == null ? "" : pending);
                    pending = null;
                }
                return true;
            case "slow":
                long ms = args.optLong(0);
                cordova.getThreadPool().execute(() -> {
                    sleep(ms);
                    cb.success();
                });
                return true;
            case "hang":
                cordova.getActivity().runOnUiThread(() -> sleep(args.optLong(0)));
                cb.success();
                return true;
            case "crash":
                cordova.getActivity().runOnUiThread(() -> {
                    throw new IllegalStateException("Example native crash");
                });
                return true;
            case "killRenderer":
                cb.success(); // answered first: the call must not outlive the renderer as a no_callback
                cordova.getActivity().runOnUiThread(() -> ((WebView) webView.getView()).loadUrl("chrome://crash"));
                return true;
            default:
                return false;
        }
    }

    /** Pushed by eval, not a keep-callback: an open call would be reported as `bridge.call` no_callback. */
    private synchronized void deliver(String scenario) {
        if (!scenario.matches("[a-z-]+")) return; // deep links are untrusted input to eval
        if (!listening) {
            pending = scenario;
            return;
        }
        String js = "window.runScenario('" + scenario + "')";
        cordova.getActivity().runOnUiThread(() -> webView.getEngine().evaluateJavascript(js, null));
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
    }
}
