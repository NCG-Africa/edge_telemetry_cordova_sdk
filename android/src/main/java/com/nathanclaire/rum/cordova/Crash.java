package com.nathanclaire.rum.cordova;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.Locale;
import java.util.Scanner;
import java.util.function.Consumer;
import java.util.function.LongSupplier;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Spec A3, E12–E15, Y3: the native breadcrumb mirror and the `app.crash` / `app.anr` /
 * `app.hang` records built from it. JVM crashes are written in-process; an NDK crash leaves a
 * plain-text report (`edge_rum_ndk.c`) that {@link #takeNdk} turns into an event next launch,
 * under the identity, session and breadcrumbs saved by {@link #saveContext} before it died.
 */
final class Crash {
    static final int BREADCRUMBS = 50;
    /** Sibling `CrashReportingService` caps. */
    private static final int MAX_MESSAGE = 1000;
    private static final int MAX_STACK = 2000;
    private static final int MAX_CAUSE = 255;
    private static final int MAX_CONTEXT = 500;
    private static final String[] SIGNAL_NAMES = new String[32];

    static {
        SIGNAL_NAMES[4] = "SIGILL";
        SIGNAL_NAMES[5] = "SIGTRAP";
        SIGNAL_NAMES[6] = "SIGABRT";
        SIGNAL_NAMES[7] = "SIGBUS";
        SIGNAL_NAMES[8] = "SIGFPE";
        SIGNAL_NAMES[11] = "SIGSEGV";
    }

    /** A record ready for {@link Outbox#writeSolo}. */
    static final class Pending {
        final String identity;
        final String event;

        Pending(String identity, String event) {
            this.identity = identity;
            this.event = event;
        }
    }

    private final File report;
    private final File context;
    private final Thread main;
    private final LongSupplier clock;
    private final ArrayDeque<Object> breadcrumbs = new ArrayDeque<>();
    private String screen;

    Crash(File dir, Thread main, LongSupplier clock) {
        dir.mkdirs();
        this.report = new File(dir, "ndk_crash.txt");
        this.context = new File(dir, "crash_context.json");
        this.main = main;
        this.clock = clock;
    }

    /** Installs the NDK signal handler writing to {@link #ndkReportPath}; idempotent (JNI, `libedgerum.so`). */
    static native void installNdk(String reportPath);

    String ndkReportPath() {
        return report.getPath();
    }

    /** A3: mirrors an `enqueue` hand-off's breadcrumbs (last 50) and its last screen. */
    synchronized void mirror(JSONObject payload) {
        JSONArray crumbs = payload.optJSONArray("breadcrumbs");
        for (int i = 0; crumbs != null && i < crumbs.length(); i++) {
            breadcrumbs.addLast(crumbs.opt(i));
            if (breadcrumbs.size() > BREADCRUMBS) breadcrumbs.removeFirst();
        }
        JSONArray events = payload.optJSONArray("events");
        for (int i = 0; events != null && i < events.length(); i++) {
            JSONObject a = events.optJSONObject(i) == null ? null : events.optJSONObject(i).optJSONObject("attributes");
            String to = a == null ? "" : a.optString("navigation.to_screen");
            if (!to.isEmpty()) screen = to;
        }
    }

    /** E12: chained JVM handler; the previous one (normally the platform's, which kills) always runs after. */
    void installJvm(Consumer<JSONObject> sink) {
        Thread.UncaughtExceptionHandler previous = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler((t, e) -> {
            try {
                sink.accept(jvm(t, e));
            } catch (Throwable ignored) {
                // Never let reporting replace the original crash.
            } finally {
                if (previous != null) previous.uncaughtException(t, e);
            }
        });
    }

    /** Y3: raw Throwable stack, N1 keys, sibling caps. */
    JSONObject jvm(Thread thread, Throwable e) throws JSONException {
        StringWriter sw = new StringWriter();
        e.printStackTrace(new PrintWriter(sw));
        String stack = sw.toString();
        Throwable cause = e.getCause();
        JSONObject a = new JSONObject()
                .put("message", cap(e.getClass().getName() + ": " + (e.getMessage() == null ? "" : e.getMessage()), MAX_MESSAGE))
                .put("stacktrace", cap(stack, MAX_STACK))
                .put("exception_type", cap(e.getClass().getSimpleName(), MAX_CAUSE))
                .put("cause", cap(cause == null || cause.getMessage() == null ? "unknown" : cause.getMessage(), MAX_CAUSE))
                .put("error_context", cap(jvmContext(stack), MAX_CONTEXT))
                .put("crash_thread", thread.getName())
                .put("crash_is_main_thread", thread == main);
        return event("app.crash", clock.getAsLong(), fatal(a));
    }

    /**
     * E13: WebView renderer death (`onRenderProcessGone`), fatal, same path as a JVM crash.
     * `reason` is `crash` or `oom_killed` (the system reclaimed it).
     */
    JSONObject webViewTerminated(String reason) throws JSONException {
        JSONObject a = new JSONObject()
                .put("message", "WebView renderer process gone (" + reason + ")")
                .put("exception_type", "WebViewTerminated")
                .put("cause", "WebViewTerminated")
                .put("webview.reason", reason)
                .put("webview.detected_by", "callback")
                .put("crash_thread", main.getName())
                .put("crash_is_main_thread", true);
        return event("app.crash", clock.getAsLong(), fatal(a));
    }

    /** E14 / E15: main-thread stall at or past its threshold. Not fatal, not handled; main stack only. */
    JSONObject stall(String name, long durationMs, String stack) throws JSONException {
        JSONObject a = new JSONObject()
                .put("message", "Main thread blocked for " + durationMs + " ms")
                .put("stacktrace", cap(stack, MAX_STACK))
                .put("crash_thread", main.getName())
                .put("crash_is_main_thread", true)
                .put("is_fatal", false)
                .put("handled", false)
                .put("app.anr".equals(name) ? "anr_duration_ms" : "hang_duration_ms", durationMs);
        String s = screen();
        if (s != null) a.put("screen_name", s);
        return event(name, clock.getAsLong(), a);
    }

    /**
     * What an NDK crash report can't know: the identity, session, user and breadcrumbs of the
     * moment. Saved after every hand-off; best effort.
     */
    void saveContext(String identity, String sessionId, String userId) {
        File tmp = new File(context.getPath() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            JSONObject a = new JSONObject().put("session.id", sessionId).put("user.id", userId);
            synchronized (this) {
                a.put("crash.breadcrumbs", new JSONArray(breadcrumbs).toString());
                if (screen != null) a.put("screen_name", screen);
            }
            out.write(new JSONObject().put("identity", identity).put("attributes", a).toString()
                    .getBytes(StandardCharsets.UTF_8));
        } catch (IOException | JSONException e) {
            return;
        }
        tmp.renameTo(context);
    }

    /**
     * Last launch's NDK crash, if any, as a solo-segment record under the crashed build's identity
     * (T4); both files deleted. A report without a usable context (or a torn one) is dropped.
     */
    Pending takeNdk() {
        if (!report.exists()) return null;
        try {
            JSONObject ctx = new JSONObject(read(context));
            return new Pending(ctx.getString("identity"), ndk(read(report), ctx.getJSONObject("attributes")).toString());
        } catch (IOException | JSONException | RuntimeException e) {
            return null;
        } finally {
            report.delete();
        }
    }

    /** P7 `disable()` / `reset()`: nothing from before survives. */
    void clear() {
        report.delete();
        context.delete();
        synchronized (this) {
            breadcrumbs.clear();
            screen = null;
        }
    }

    /** Y3: frames as a tombstone backtrace (`#00 pc <rel pc>  <image> (BuildId: <id>)`), ndk-stack readable. */
    static JSONObject ndk(String report, JSONObject context) throws JSONException {
        int signal = -1;
        int code = 0;
        long faultAddr = 0;
        long at = 0;
        long pid = -1;
        long tid = -2;
        String thread = "";
        StringBuilder stack = new StringBuilder();
        String top = null;
        int n = 0;
        for (String line : report.split("\n")) {
            int sp = line.indexOf(' ');
            if (sp < 0) continue;
            String key = line.substring(0, sp);
            String value = line.substring(sp + 1);
            switch (key) {
                case "signal": signal = Integer.parseInt(value); break;
                case "code": code = Integer.parseInt(value); break;
                case "fault_addr": faultAddr = new BigInteger(value, 16).longValue(); break;
                case "time_ms": at = Long.parseLong(value); break;
                case "pid": pid = Long.parseLong(value); break;
                case "tid": tid = Long.parseLong(value); break;
                case "thread": thread = value; break;
                case "frame":
                    // `<rel pc hex> <build id hex | -> <image path>`
                    String[] f = value.split(" ", 3);
                    if (f.length < 3) break;
                    String image = f[2];
                    stack.append(String.format(Locale.US, "#%02d pc %016x  %s", n++, new BigInteger(f[0], 16).longValue(), image));
                    if (!"-".equals(f[1])) stack.append(" (BuildId: ").append(f[1]).append(')');
                    stack.append('\n');
                    if (top == null) top = image.substring(image.lastIndexOf('/') + 1) + "+0x" + f[0];
                    break;
                default:
                    break;
            }
        }
        if (signal < 0) throw new JSONException("no signal in NDK report");
        String name = signal < SIGNAL_NAMES.length && SIGNAL_NAMES[signal] != null ? SIGNAL_NAMES[signal] : "SIG" + signal;
        JSONObject a = new JSONObject()
                .put("message", String.format(Locale.US, "%s, code %d, fault addr 0x%x", name, code, faultAddr))
                .put("stacktrace", cap(stack.toString(), MAX_STACK))
                .put("exception_type", name)
                .put("cause", "signal " + signal)
                .put("error_context", top == null ? "unknown" : top)
                .put("crash_thread", thread)
                .put("crash_is_main_thread", pid == tid);
        JSONArray keys = context.names();
        for (int i = 0; keys != null && i < keys.length(); i++) a.put(keys.getString(i), context.get(keys.getString(i)));
        return event("app.crash", at, fatalFlags(a));
    }

    private JSONObject fatal(JSONObject a) throws JSONException {
        String crumbs;
        String s;
        synchronized (this) {
            crumbs = new JSONArray(breadcrumbs).toString();
            s = screen;
        }
        a.put("crash.breadcrumbs", crumbs);
        if (s != null) a.put("screen_name", s);
        return fatalFlags(a);
    }

    private static JSONObject fatalFlags(JSONObject a) throws JSONException {
        return a.put("is_fatal", true).put("handled", false);
    }

    private synchronized String screen() {
        return screen;
    }

    static JSONObject event(String name, long at, JSONObject attrs) throws JSONException {
        return new JSONObject()
                .put("type", "event")
                .put("eventName", name)
                .put("timestamp", Sender.rfc3339(at))
                .put("attributes", attrs);
    }

    /** Sibling `extractErrorContext`: `Class.method` of the first `at` frame. */
    private static String jvmContext(String stack) {
        for (String line : stack.split("\n")) {
            String l = line.trim();
            if (!l.startsWith("at ")) continue;
            String method = l.substring(3);
            int paren = method.indexOf('(');
            if (paren > 0) method = method.substring(0, paren);
            String[] parts = method.split("\\.");
            return parts.length >= 2 ? parts[parts.length - 2] + "." + parts[parts.length - 1] : method;
        }
        return "unknown";
    }

    private static String cap(String s, int max) {
        return s.length() <= max ? s : s.substring(0, max);
    }

    private static String read(File f) throws IOException {
        try (Scanner in = new Scanner(f, "UTF-8").useDelimiter("\\A")) {
            return in.hasNext() ? in.next() : "";
        }
    }
}
