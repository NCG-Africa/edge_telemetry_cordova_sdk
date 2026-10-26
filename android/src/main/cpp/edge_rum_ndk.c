// Spec E12 / Y3: NDK signal handler. Writes a plain-text report that Crash.takeNdk turns into a
// persisted app.crash on next launch, then hands the signal to whoever had it before (debuggerd).
//
// Report lines: `signal`, `code`, `fault_addr` (hex), `time_ms`, `pid`, `tid`, `thread`, then one
// `frame <rel pc hex> <ELF build id hex | -> <image path>` per frame, faulting pc first.
//
// ponytail: dladdr and the unwinder aren't strictly async-signal-safe (as in most in-process
// reporters); a crash inside the dynamic linker can deadlock here. Upgrade path: a ucontext-driven
// unwinder over a map snapshot taken at install, if that shows up in the field.
#include <dlfcn.h>
#include <elf.h>
#include <fcntl.h>
#include <jni.h>
#include <link.h>
#include <signal.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>
#include <unwind.h>

#define MAX_FRAMES 64
#define ALIGN4(n) (((n) + 3u) & ~3u)

static const int SIGNALS[] = {SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP};
#define NSIGNALS (sizeof(SIGNALS) / sizeof(SIGNALS[0]))

static struct sigaction previous[NSIGNALS];
static char report_path[1024];
static char tmp_path[sizeof report_path + 4];
static uintptr_t page_size = 4096;
static volatile sig_atomic_t installed;
static volatile sig_atomic_t handling;

static void put(int fd, const char *s) {
    write(fd, s, strlen(s));
}

static void put_hex(int fd, uintptr_t v) {
    char b[2 * sizeof v + 1];
    int i = sizeof b - 1;
    b[i] = 0;
    do {
        b[--i] = "0123456789abcdef"[v & 15];
        v >>= 4;
    } while (v && i);
    put(fd, b + i);
}

static void put_dec(int fd, long long v) {
    char b[24];
    int i = sizeof b - 1;
    unsigned long long u = v < 0 ? -(unsigned long long)v : (unsigned long long)v;
    b[i] = 0;
    do {
        b[--i] = (char)('0' + u % 10);
        u /= 10;
    } while (u && i > 1);
    if (v < 0) b[--i] = '-';
    put(fd, b + i);
}

typedef struct {
    uintptr_t pcs[MAX_FRAMES];
    int n;
} frames_t;

static _Unwind_Reason_Code on_frame(struct _Unwind_Context *ctx, void *arg) {
    frames_t *f = arg;
    uintptr_t pc = _Unwind_GetIP(ctx);
    if (pc && f->n < MAX_FRAMES) f->pcs[f->n++] = pc;
    return f->n < MAX_FRAMES ? _URC_NO_REASON : _URC_END_OF_STACK;
}

static uintptr_t fault_pc(const ucontext_t *uc) {
#if defined(__aarch64__)
    return uc->uc_mcontext.pc;
#elif defined(__arm__)
    return uc->uc_mcontext.arm_pc;
#elif defined(__x86_64__)
    return uc->uc_mcontext.gregs[REG_RIP];
#elif defined(__i386__)
    return uc->uc_mcontext.gregs[REG_EIP];
#else
    return 0;
#endif
}

// Y3: pc relative to the image's load bias + its GNU build id, read from the mapped ELF headers.
static void put_frame(int fd, uintptr_t pc) {
    Dl_info info;
    put(fd, "frame ");
    const ElfW(Ehdr) *eh = NULL;
    if (dladdr((void *)pc, &info) && info.dli_fbase) eh = info.dli_fbase;
    if (!eh || memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0) {
        put_hex(fd, pc);
        put(fd, " - ");
        put(fd, eh && info.dli_fname ? info.dli_fname : "?");
        put(fd, "\n");
        return;
    }
    const ElfW(Phdr) *ph = (const void *)((const char *)eh + eh->e_phoff);
    uintptr_t min_vaddr = UINTPTR_MAX;
    for (int i = 0; i < eh->e_phnum; i++) {
        if (ph[i].p_type == PT_LOAD && ph[i].p_vaddr < min_vaddr) min_vaddr = ph[i].p_vaddr;
    }
    uintptr_t bias = (uintptr_t)eh - (min_vaddr & ~(page_size - 1));
    put_hex(fd, pc - bias);
    put(fd, " ");
    int found = 0;
    for (int i = 0; i < eh->e_phnum && !found; i++) {
        if (ph[i].p_type != PT_NOTE) continue;
        const char *p = (const char *)(bias + ph[i].p_vaddr);
        const char *end = p + ph[i].p_memsz;
        while (!found && p + sizeof(ElfW(Nhdr)) <= end) {
            const ElfW(Nhdr) *note = (const void *)p;
            const char *name = p + sizeof *note;
            const unsigned char *desc = (const unsigned char *)name + ALIGN4(note->n_namesz);
            if (note->n_type == NT_GNU_BUILD_ID && note->n_namesz == 4 && memcmp(name, "GNU", 4) == 0) {
                char hex[3] = {0};
                for (unsigned j = 0; j < note->n_descsz; j++) {
                    hex[0] = "0123456789abcdef"[desc[j] >> 4];
                    hex[1] = "0123456789abcdef"[desc[j] & 15];
                    put(fd, hex);
                }
                found = 1;
            }
            p = (const char *)desc + ALIGN4(note->n_descsz);
        }
    }
    if (!found) put(fd, "-");
    put(fd, " ");
    put(fd, info.dli_fname ? info.dli_fname : "?");
    put(fd, "\n");
}

static void report(int sig, const siginfo_t *info, const ucontext_t *uc) {
    // Written aside and renamed, so a kill mid-write never leaves a torn report in place.
    int fd = open(tmp_path, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return;
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    char thread[17] = {0};
    prctl(PR_GET_NAME, thread);
    put(fd, "signal ");
    put_dec(fd, sig);
    put(fd, "\ncode ");
    put_dec(fd, info->si_code);
    put(fd, "\nfault_addr ");
    put_hex(fd, (uintptr_t)info->si_addr);
    put(fd, "\ntime_ms ");
    put_dec(fd, (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000);
    put(fd, "\npid ");
    put_dec(fd, getpid());
    put(fd, "\ntid ");
    put_dec(fd, gettid());
    put(fd, "\nthread ");
    put(fd, thread);
    put(fd, "\n");

    frames_t frames = {.n = 0};
    _Unwind_Backtrace(on_frame, &frames);
    uintptr_t pc = fault_pc(uc);
    // The unwinder starts in this handler; skip to the faulting frame when it finds it.
    int start = 0;
    for (int i = 0; i < frames.n; i++) {
        if (frames.pcs[i] == pc) {
            start = i + 1;
            break;
        }
    }
    if (pc) put_frame(fd, pc);
    for (int i = start; i < frames.n; i++) put_frame(fd, frames.pcs[i]);
    close(fd);
    rename(tmp_path, report_path);
}

static void handle(int sig, siginfo_t *info, void *uc) {
    // A second fault while reporting goes straight to the chain.
    if (!handling) {
        handling = 1;
        report(sig, info, uc);
    }
    for (unsigned i = 0; i < NSIGNALS; i++) {
        if (SIGNALS[i] != sig) continue;
        struct sigaction *p = &previous[i];
        if ((p->sa_flags & SA_SIGINFO) && p->sa_sigaction) {
            p->sa_sigaction(sig, info, uc);
            return;
        }
        if (!(p->sa_flags & SA_SIGINFO) && p->sa_handler != SIG_DFL && p->sa_handler != SIG_IGN) {
            p->sa_handler(sig);
            return;
        }
        // Default action: restore it; a fault re-fires on return, a sent signal is re-sent.
        sigaction(sig, p, NULL);
        if (info->si_code <= 0) syscall(SYS_tgkill, getpid(), gettid(), sig);
        return;
    }
}

JNIEXPORT void JNICALL Java_com_nathanclaire_rum_cordova_Crash_installNdk(JNIEnv *env, jclass cls, jstring path) {
    (void)cls;
    if (installed) return;
    const char *p = (*env)->GetStringUTFChars(env, path, NULL);
    if (!p) return;
    strncpy(report_path, p, sizeof report_path - 1);
    (*env)->ReleaseStringUTFChars(env, path, p);
    memcpy(tmp_path, report_path, sizeof report_path);
    strcat(tmp_path, ".tmp");
    long ps = sysconf(_SC_PAGESIZE);
    if (ps > 0) page_size = (uintptr_t)ps;

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sigemptyset(&sa.sa_mask);
    sa.sa_sigaction = handle;
    // Bionic gives every thread an alternate signal stack, so stack overflows are caught too.
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    for (unsigned i = 0; i < NSIGNALS; i++) sigaction(SIGNALS[i], &sa, &previous[i]);
    installed = 1;
}
