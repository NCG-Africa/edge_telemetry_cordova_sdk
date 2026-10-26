package com.nathanclaire.rum.cordova;

import java.util.function.Consumer;
import java.util.function.LongSupplier;
import java.util.function.ObjLongConsumer;
import java.util.function.Supplier;

/**
 * Spec E14, E15: main-thread watchdog, ported from the sibling `AnrWatchdog`. A daemon thread posts
 * a heartbeat to the main looper; how long it takes to run is read against the hang line
 * (`EdgeRumHangTimeoutMs`) and the ANR line (`EdgeRumAnrTimeoutMs`). One stall past both fires
 * both, once each; the latches clear when the main thread answers. A threshold ≤ 0 is off.
 * Foreground only: started on resume, stopped on pause.
 */
final class Watchdog {
    private static final String THREAD_NAME = "edge-rum-watchdog";

    private final long hangMs;
    private final long anrMs;
    private final Consumer<Runnable> postToMain;
    private final LongSupplier clock;
    private final Supplier<String> mainStack;
    private final ObjLongConsumer<String> onHang;
    private final ObjLongConsumer<String> onAnr;

    private volatile boolean waiting;
    private volatile long pendingSince;
    private volatile boolean hangFired;
    private volatile boolean anrFired;
    private Thread worker;

    private final Runnable pong = () -> {
        waiting = false;
        hangFired = false;
        anrFired = false;
    };

    Watchdog(long hangMs, long anrMs, Consumer<Runnable> postToMain, LongSupplier clock, Supplier<String> mainStack,
            ObjLongConsumer<String> onHang, ObjLongConsumer<String> onAnr) {
        this.hangMs = hangMs;
        this.anrMs = anrMs;
        this.postToMain = postToMain;
        this.clock = clock;
        this.mainStack = mainStack;
        this.onHang = onHang;
        this.onAnr = onAnr;
    }

    /** Half the lowest enabled line, so a stall at the line is seen within one scan; 0 when both are off. */
    long intervalMs() {
        long lowest = Math.min(hangMs > 0 ? hangMs : Long.MAX_VALUE, anrMs > 0 ? anrMs : Long.MAX_VALUE);
        return lowest == Long.MAX_VALUE ? 0 : Math.max(1, lowest / 2);
    }

    synchronized void start() {
        long interval = intervalMs();
        if (worker != null || interval == 0) return;
        waiting = false;
        Thread t = new Thread(() -> {
            while (!Thread.currentThread().isInterrupted()) {
                scanOnce();
                try {
                    Thread.sleep(interval);
                } catch (InterruptedException e) {
                    return;
                }
            }
        }, THREAD_NAME);
        t.setDaemon(true);
        worker = t;
        t.start();
    }

    synchronized void stop() {
        if (worker != null) worker.interrupt();
        worker = null;
    }

    /** One heartbeat cycle; tests drive it with a fake clock. */
    void scanOnce() {
        if (!waiting) {
            waiting = true;
            hangFired = false;
            anrFired = false;
            pendingSince = clock.getAsLong();
            postToMain.accept(pong);
            return;
        }
        long blocked = clock.getAsLong() - pendingSince;
        boolean hang = hangMs > 0 && !hangFired && blocked >= hangMs;
        boolean anr = anrMs > 0 && !anrFired && blocked >= anrMs;
        if (!hang && !anr) return;
        // One stack per scan: a stall crossing both lines in one read reports the same frames.
        String stack = mainStack.get();
        if (hang) {
            hangFired = true;
            onHang.accept(stack, blocked);
        }
        if (anr) {
            anrFired = true;
            onAnr.accept(stack, blocked);
        }
    }
}
