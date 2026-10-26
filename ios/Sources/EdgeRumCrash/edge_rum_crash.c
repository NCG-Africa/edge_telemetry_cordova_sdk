// Spec E12 / Y3: signal + Mach exception handlers. Each writes a plain-text report that
// Crash.takeReport turns into a persisted app.crash on next launch, then hands the crash on.
//
// Report lines: `exception`, `mach_code`, `mach_subcode` (hex; Mach) or `signal`, `code`,
// `fault_addr` (hex; signal), then `time_ms`, `thread`, `main` (1|0), then one
// `frame <pc>\t<base>\t<LC_UUID>\t<image path>\t<symbol>` per frame (hex, `-` = none),
// faulting pc first. The first handler to fire writes; a Mach exception is reported there and
// the BSD signal the kernel raises after it only chains on.
//
// ponytail: dladdr isn't strictly async-signal-safe (as in most in-process reporters, and the
// Android NDK handler); a crash inside dyld can deadlock here. Upgrade path: an image table
// snapshotted at install, if that shows up in the field.
// ponytail: a host that handles SIGSEGV itself and carries on still leaves a Mach-written report
// (as KSCrash); the next launch sends it as a crash.
#include "edge_rum_crash.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

#define MAX_FRAMES 64
#define EXC_MASK (EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_BREAKPOINT)

static const int SIGNALS[] = {SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP};
#define NSIGNALS (sizeof(SIGNALS) / sizeof(SIGNALS[0]))

static struct sigaction previous[NSIGNALS];
static char report_path[1024];
static char tmp_path[sizeof report_path + 4];
static volatile int reported;
static thread_t main_thread = MACH_PORT_NULL;
static pthread_once_t once = PTHREAD_ONCE_INIT;

/// Image load runs on the main thread: its port, for the Mach handler and hang stacks.
__attribute__((constructor)) static void capture_main_thread(void) {
    if (pthread_main_np()) main_thread = pthread_mach_thread_np(pthread_self());
}

static mach_port_t exc_port = MACH_PORT_NULL;
static mach_msg_type_number_t prev_count;
static exception_mask_t prev_masks[EXC_TYPES_COUNT];
static mach_port_t prev_ports[EXC_TYPES_COUNT];
static exception_behavior_t prev_behaviors[EXC_TYPES_COUNT];
static thread_state_flavor_t prev_flavors[EXC_TYPES_COUNT];

typedef struct {
    uintptr_t pc, fp, lr;
} regs_t;

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

static uintptr_t strip(uintptr_t p) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)p, ptrauth_key_return_address);
#else
    return p;
#endif
}

/// Reads memory that may be unmapped without faulting.
static int peek(uintptr_t addr, void *out, size_t n) {
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)addr, n, (vm_address_t)out, &got) == KERN_SUCCESS
        && got == n;
}

/// Frame-pointer walk (mandatory on Apple arm64): pc, lr, then each saved return address.
static int walk(regs_t r, uintptr_t *pcs, int max) {
    int n = 0;
    if (r.pc && n < max) pcs[n++] = strip(r.pc);
    uintptr_t lr = strip(r.lr);
    if (lr && n < max) pcs[n++] = lr;
    uintptr_t fp = r.fp;
    for (int first = 1; fp && n < max; first = 0) {
        uintptr_t frame[2];
        if (!peek(fp, frame, sizeof frame)) break;
        uintptr_t ret = strip(frame[1]);
        if (!ret) break;
        // A non-leaf frame saved lr as its return address: don't list it twice.
        if (!(first && ret == lr)) pcs[n++] = ret;
        // The stack grows down: a chain that doesn't climb is corrupt or loops.
        if (frame[0] <= fp) break;
        fp = frame[0];
    }
    return n;
}

static int thread_regs(thread_t t, regs_t *r) {
#if defined(__arm64__)
    arm_thread_state64_t s;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(t, ARM_THREAD_STATE64, (thread_state_t)&s, &count) != KERN_SUCCESS) return 0;
    *r = (regs_t){arm_thread_state64_get_pc(s), arm_thread_state64_get_fp(s), arm_thread_state64_get_lr(s)};
    return 1;
#elif defined(__x86_64__)
    x86_thread_state64_t s;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(t, x86_THREAD_STATE64, (thread_state_t)&s, &count) != KERN_SUCCESS) return 0;
    *r = (regs_t){s.__rip, s.__rbp, 0};
    return 1;
#else
    return 0;
#endif
}

static regs_t context_regs(const ucontext_t *uc) {
#if defined(__arm64__)
    return (regs_t){arm_thread_state64_get_pc(uc->uc_mcontext->__ss), arm_thread_state64_get_fp(uc->uc_mcontext->__ss),
                    arm_thread_state64_get_lr(uc->uc_mcontext->__ss)};
#elif defined(__x86_64__)
    return (regs_t){uc->uc_mcontext->__ss.__rip, uc->uc_mcontext->__ss.__rbp, 0};
#else
    return (regs_t){0, 0, 0};
#endif
}

int edge_rum_image(uintptr_t pc, uintptr_t *base, char *uuid, const char **path, const char **symbol) {
    Dl_info info;
    uuid[0] = 0;
    if (!dladdr((const void *)pc, &info) || !info.dli_fbase) return 0;
    *base = (uintptr_t)info.dli_fbase;
    *path = info.dli_fname;
    *symbol = info.dli_sname;
    const struct mach_header_64 *mh = info.dli_fbase;
    if (mh->magic != MH_MAGIC_64) return 1;
    const char *cmd = (const char *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const void *)cmd;
        if (lc->cmd == LC_UUID) {
            const uint8_t *u = ((const struct uuid_command *)lc)->uuid;
            for (int j = 0; j < 16; j++) {
                uuid[2 * j] = "0123456789abcdef"[u[j] >> 4];
                uuid[2 * j + 1] = "0123456789abcdef"[u[j] & 15];
            }
            uuid[32] = 0;
            break;
        }
        if (lc->cmdsize == 0) break; // malformed header: stop, never loop
        cmd += lc->cmdsize;
    }
    return 1;
}

static void put_frame(int fd, uintptr_t pc) {
    uintptr_t base = 0;
    char uuid[33];
    const char *path = NULL;
    const char *symbol = NULL;
    int found = edge_rum_image(pc, &base, uuid, &path, &symbol);
    put(fd, "frame ");
    put_hex(fd, pc);
    put(fd, "\t");
    if (found) put_hex(fd, base);
    else put(fd, "-");
    put(fd, "\t");
    put(fd, uuid[0] ? uuid : "-");
    put(fd, "\t");
    put(fd, path ? path : "-");
    put(fd, "\t");
    put(fd, symbol ? symbol : "-");
    put(fd, "\n");
}

/// Written aside and renamed, so a kill mid-write never leaves a torn report in place.
static int begin_report(void) {
    return open(tmp_path, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0600);
}

static void end_report(int fd, const char *thread, int is_main, regs_t regs) {
    struct timeval now;
    gettimeofday(&now, NULL);
    put(fd, "time_ms ");
    put_dec(fd, (long long)now.tv_sec * 1000 + now.tv_usec / 1000);
    put(fd, "\nthread ");
    put(fd, thread);
    put(fd, "\nmain ");
    put(fd, is_main ? "1" : "0");
    put(fd, "\n");
    uintptr_t pcs[MAX_FRAMES];
    int n = walk(regs, pcs, MAX_FRAMES);
    for (int i = 0; i < n; i++) put_frame(fd, pcs[i]);
    close(fd);
    rename(tmp_path, report_path);
}

static void handle(int sig, siginfo_t *info, void *uc) {
    // First reporter wins: a Mach handler already wrote this crash, or a second fault while reporting.
    if (__sync_bool_compare_and_swap(&reported, 0, 1)) {
        int fd = begin_report();
        if (fd >= 0) {
            char thread[64] = {0};
            pthread_getname_np(pthread_self(), thread, sizeof thread);
            put(fd, "signal ");
            put_dec(fd, sig);
            put(fd, "\ncode ");
            put_dec(fd, info->si_code);
            put(fd, "\nfault_addr ");
            put_hex(fd, (uintptr_t)info->si_addr);
            put(fd, "\n");
            end_report(fd, thread, pthread_main_np(), context_regs(uc));
        }
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
        if (info->si_code <= 0 || info->si_code >= SI_USER) raise(sig);
        return;
    }
}

/// `__Request__mach_exception_raise_t` (EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES), with room to spare.
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    NDR_record_t ndr;
    exception_type_t exception;
    mach_msg_type_number_t code_count;
    int64_t code[2];
    char padding[512];
} exc_request_t;

typedef struct {
    mach_msg_header_t header;
    NDR_record_t ndr;
    kern_return_t ret;
} exc_reply_t;

/// - Returns: 0 when nothing was written, leaving the crash to the signal handler.
static int report_mach(const exc_request_t *msg) {
    thread_t t = msg->thread.name;
    regs_t regs = {0, 0, 0};
    if (!thread_regs(t, &regs)) return 0;
    int fd = begin_report();
    if (fd < 0) return 0;
    thread_extended_info_data_t info;
    mach_msg_type_number_t count = THREAD_EXTENDED_INFO_COUNT;
    if (thread_info(t, THREAD_EXTENDED_INFO, (thread_info_t)&info, &count) != KERN_SUCCESS) info.pth_name[0] = 0;
    info.pth_name[sizeof info.pth_name - 1] = 0;
    put(fd, "exception ");
    put_dec(fd, msg->exception);
    put(fd, "\nmach_code ");
    put_hex(fd, msg->code_count > 0 ? (uintptr_t)msg->code[0] : 0);
    put(fd, "\nmach_subcode ");
    put_hex(fd, msg->code_count > 1 ? (uintptr_t)msg->code[1] : 0);
    put(fd, "\n");
    end_report(fd, info.pth_name, t == main_thread, regs);
    return 1;
}

static void *mach_loop(void *arg) {
    (void)arg;
    pthread_setname_np("edge-rum-exceptions");
    for (;;) {
        exc_request_t msg;
        if (mach_msg(&msg.header, MACH_RCV_MSG, 0, sizeof msg, exc_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL)
            != MACH_MSG_SUCCESS) continue;
        if (__sync_bool_compare_and_swap(&reported, 0, 1) && !report_mach(&msg)) reported = 0;
        // Hand back: previous ports restored, then KERN_FAILURE so the kernel raises the BSD
        // signal, whose handler chains to whoever had it before.
        for (mach_msg_type_number_t i = 0; i < prev_count; i++) {
            task_set_exception_ports(mach_task_self(), prev_masks[i], prev_ports[i], prev_behaviors[i], prev_flavors[i]);
        }
        exc_reply_t reply;
        memset(&reply, 0, sizeof reply);
        reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(msg.header.msgh_bits), 0);
        reply.header.msgh_remote_port = msg.header.msgh_remote_port;
        reply.header.msgh_size = sizeof reply;
        reply.header.msgh_id = msg.header.msgh_id + 100;
        reply.ndr = NDR_record;
        reply.ret = KERN_FAILURE;
        mach_msg(&reply.header, MACH_SEND_MSG, sizeof reply, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    }
    return NULL;
}

/// A debugger owns the exception ports; taking them would hide its stops.
static int debugged(void) {
    struct kinfo_proc info;
    size_t size = sizeof info;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    info.kp_proc.p_flag = 0;
    return sysctl(mib, 4, &info, &size, NULL, 0) == 0 && (info.kp_proc.p_flag & P_TRACED);
}

static void install_mach(void) {
    mach_port_t task = mach_task_self();
    if (mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &exc_port) != KERN_SUCCESS) return;
    if (mach_port_insert_right(task, exc_port, exc_port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) return;
    prev_count = EXC_TYPES_COUNT;
    if (task_get_exception_ports(task, EXC_MASK, prev_masks, &prev_count, prev_ports, prev_behaviors, prev_flavors)
        != KERN_SUCCESS) prev_count = 0;
    pthread_t thread;
    if (pthread_create(&thread, NULL, mach_loop, NULL) != 0) return;
    pthread_detach(thread);
    task_set_exception_ports(task, EXC_MASK, exc_port, (exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES),
                             THREAD_STATE_NONE);
}

static char *install_path;

static void install(void) {
    strncpy(report_path, install_path, sizeof report_path - 1);
    memcpy(tmp_path, report_path, sizeof report_path);
    strcat(tmp_path, ".tmp");

    // Room to report a stack overflow on this thread (main).
    stack_t alt = {.ss_sp = malloc(SIGSTKSZ), .ss_size = SIGSTKSZ, .ss_flags = 0};
    if (alt.ss_sp) sigaltstack(&alt, NULL);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sigemptyset(&sa.sa_mask);
    sa.sa_sigaction = handle;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    for (unsigned i = 0; i < NSIGNALS; i++) sigaction(SIGNALS[i], &sa, &previous[i]);

    if (!debugged()) install_mach();
}

void edge_rum_crash_install(const char *path) {
    install_path = (char *)path;
    pthread_once(&once, install);
}

int edge_rum_main_stack(uintptr_t *pcs, int max) {
    thread_t t = main_thread;
    if (pthread_main_np() || t == MACH_PORT_NULL) return 0;
    if (thread_suspend(t) != KERN_SUCCESS) return 0;
    // Nothing that takes a lock while main is stopped: it may hold it.
    regs_t regs;
    int n = thread_regs(t, &regs) ? walk(regs, pcs, max) : 0;
    thread_resume(t);
    return n;
}
