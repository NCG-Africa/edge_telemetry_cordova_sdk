package com.nathanclaire.rum.cordova;

import static org.junit.Assert.assertEquals;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import org.junit.Test;

public class WatchdogTest {
    long now;
    final List<Runnable> posted = new ArrayList<>();
    final List<String> fired = new ArrayList<>();

    Watchdog watchdog(long hangMs, long anrMs) {
        return new Watchdog(hangMs, anrMs, posted::add, () -> now, () -> "at main",
                (stack, ms) -> fired.add("hang " + ms), (stack, ms) -> fired.add("anr " + ms));
    }

    /** Scans every 1 s of a stall of `ms`, main thread never answering. */
    void stall(Watchdog w, long ms) {
        w.scanOnce();
        for (long t = 0; t < ms; t += 1_000) {
            now += 1_000;
            w.scanOnce();
        }
    }

    @Test public void oneStallPastBothLinesFiresEachOnce() {
        Watchdog w = watchdog(2_000, 5_000);
        stall(w, 7_000);
        assertEquals(Arrays.asList("hang 2000", "anr 5000"), fired);
    }

    @Test public void belowTheHangLineNothingFires() {
        Watchdog w = watchdog(2_000, 5_000);
        stall(w, 1_000);
        assertEquals(Collections.emptyList(), fired);
    }

    @Test public void answeredHeartbeatRearmsForTheNextStall() {
        Watchdog w = watchdog(2_000, 5_000);
        stall(w, 3_000);
        posted.get(0).run(); // main thread free again
        stall(w, 2_000);
        assertEquals(Arrays.asList("hang 2000", "hang 2000"), fired);
        assertEquals("one heartbeat per stall", 2, posted.size());
    }

    @Test public void configuredThresholdsAndOffSwitches() {
        stall(watchdog(0, 3_000), 4_000);
        assertEquals(Collections.singletonList("anr 3000"), fired);
        fired.clear();
        stall(watchdog(1_000, 0), 4_000);
        assertEquals(Collections.singletonList("hang 1000"), fired);
    }

    @Test public void intervalIsHalfTheLowestEnabledLine() {
        assertEquals(1_000, watchdog(2_000, 5_000).intervalMs());
        assertEquals(2_500, watchdog(0, 5_000).intervalMs());
        assertEquals("both off: never started", 0, watchdog(0, 0).intervalMs());
    }
}
