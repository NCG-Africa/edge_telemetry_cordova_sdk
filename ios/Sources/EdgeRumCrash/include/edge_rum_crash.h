// Spec E12, E15, Y3: native crash capture and main-thread stacks for the Swift core.
#ifndef EDGE_RUM_CRASH_H
#define EDGE_RUM_CRASH_H

#include <stdint.h>

/// Installs the signal handlers (alternate stack for the calling thread, so call on main) and,
/// unless a debugger is attached, the Mach exception handler. Each writes a plain-text report to
/// `path` (aside, then renamed) that `Crash.takeReport` turns into an `app.crash` next launch. Once per
/// process; later calls do nothing.
void edge_rum_crash_install(const char *path);

/// The main thread's return addresses, innermost first, walked while it is briefly suspended.
/// - Returns: the number written to `pcs`; 0 on main itself or on failure.
int edge_rum_main_stack(uintptr_t *pcs, int max);

/// Y3: the Mach-O image holding `pc` (`dladdr`): load base, LC_UUID as 32 lowercase hex chars
/// (`uuid` holds 33 bytes; empty when the image has none), path, nearest symbol (NULL if none).
/// - Returns: 0 when no image holds `pc`.
int edge_rum_image(uintptr_t pc, uintptr_t *base, char *uuid, const char **path, const char **symbol);

#endif
