#define _GNU_SOURCE

#include "proc_control.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <sys/timerfd.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define SOCKET_PATH "/dev/.hyperos4-launcher-scheduling/source-guard.sock"
#define STATUS_PATH "/dev/.hyperos4-launcher-scheduling/source-guard.status"
#define TRACE_ID_PATH "/sys/kernel/tracing/events/cgroup/cgroup_attach_task/id"
#define TRACE_FORMAT_PATH "/sys/kernel/tracing/events/cgroup/cgroup_attach_task/format"
#define SOURCE_CPUSET_PROCS "/dev/cpuset/hyperos4-source/cgroup.procs"
#define SOURCE_CPUCTL_PROCS "/dev/cpuctl/hyperos4-source/cgroup.procs"
#define SOURCE_CPUSET_TASKS "/dev/cpuset/hyperos4-source/tasks"
#define SOURCE_CPUCTL_TASKS "/dev/cpuctl/hyperos4-source/tasks"
#define TOP_CPUSET_PROCS "/dev/cpuset/top-app/cgroup.procs"
#define TOP_CPUCTL_PROCS "/dev/cpuctl/top-app/cgroup.procs"
#define BACKGROUND_CPUSET_PROCS "/dev/cpuset/background/cgroup.procs"
#define BACKGROUND_CPUCTL_PROCS "/dev/cpuctl/background/cgroup.procs"
#define NICE_FILE "/data/adb/hyperos4-launcher-scheduling/source-nice-suppression"
#define TOPOLOGY_FILE "/data/adb/modules/hyperos4_recents_source_app_yield/launcher-thread-topology"
#define MINOR_WINDOW_NODE "/sys/module/metis/parameters/minor_window_app"
#define SOURCE_GROUP "/hyperos4-source"
#define MAX_TASKS 4096
#define TASK_HASH_SIZE 8192
#define PERF_PAGES 8
#define PACKAGE_LENGTH 256

struct task_state {
    pid_t tid;
    unsigned long long starttime;
    int original_nice;
    int applied_nice;
    uint64_t original_affinity;
    int affinity_valid;
};

struct guard_state {
    pid_t pid;
    uid_t uid;
    unsigned long long starttime;
    int armed;
    int active;
    int original_minor_valid;
    long original_minor;
    unsigned long reassertions;
    unsigned long affinity_restore_attempts;
    unsigned long affinity_restore_successes;
    unsigned long nice_restore_attempts;
    unsigned long nice_restore_successes;
    char package[PACKAGE_LENGTH];
    int target_nice;
    struct task_state tasks[MAX_TASKS];
    uint16_t task_slots[TASK_HASH_SIZE];
    size_t task_count;
};

struct perf_ring {
    int fd;
    void *mapping;
    size_t mapping_size;
    size_t data_size;
};

static struct guard_state state;
static volatile sig_atomic_t running = 1;
static struct perf_ring trace_rings[64];
static int trace_ring_count;
static int trace_enabled;
static size_t trace_pid_offset;
static size_t trace_path_loc_offset;
static int task_directory_fd = -1;
static int completion_timer_fd = -1;
static uint64_t accepted_transition_id;
static uint64_t completion_transition_id;

static int set_trace_enabled(int enabled);

static int read_text(const char *path, char *buffer, size_t size) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    ssize_t length;
    if (fd < 0) return -1;
    length = read(fd, buffer, size - 1);
    close(fd);
    if (length <= 0) return -1;
    buffer[length] = '\0';
    return 0;
}

static long read_number(const char *path) {
    char text[64];
    char *end;
    long value;
    if (read_text(path, text, sizeof(text)) != 0) return -1;
    errno = 0;
    value = strtol(text, &end, 10);
    return errno == 0 && end != text ? value : -1;
}

static int write_number(const char *path, long value) {
    char text[64];
    int fd;
    int length = snprintf(text, sizeof(text), "%ld\n", value);
    if (length <= 0 || (size_t)length >= sizeof(text)) return -1;
    fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    if (write(fd, text, (size_t)length) != length) {
        close(fd);
        return -1;
    }
    close(fd);
    return 0;
}

static int write_pid(const char *path, pid_t pid) {
    return write_number(path, (long)pid);
}

static void close_task_directory(void) {
    if (task_directory_fd >= 0) close(task_directory_fd);
    task_directory_fd = -1;
}

static void reset_guard_state(void) {
    close_task_directory();
    memset(&state, 0, sizeof(state));
}

static void cancel_completion_timer(void) {
    struct itimerspec timer = {0};
    completion_transition_id = 0;
    if (completion_timer_fd >= 0)
        (void)timerfd_settime(completion_timer_fd, 0, &timer, NULL);
}

static int open_task_directory(pid_t pid) {
    char path[64];
    close_task_directory();
    snprintf(path, sizeof(path), "/proc/%d/task", pid);
    task_directory_fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    return task_directory_fd >= 0 ? 0 : -1;
}

static int task_belongs_to_source(pid_t tid) {
    char name[32];
    struct stat metadata;
    if (task_directory_fd >= 0) {
        snprintf(name, sizeof(name), "%d", tid);
        return fstatat(task_directory_fd, name, &metadata, 0) == 0;
    }
    {
        char path[96];
        snprintf(path, sizeof(path), "/proc/%d/task/%d", state.pid, tid);
        return stat(path, &metadata) == 0;
    }
}

static int read_process_identity(pid_t pid, uid_t *uid,
                                 unsigned long long *starttime) {
    char path[64];
    char text[4096];
    char *cursor;
    struct stat metadata;
    long long value = 0;
    snprintf(path, sizeof(path), "/proc/%d", pid);
    if (stat(path, &metadata) != 0) return -1;
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    if (read_text(path, text, sizeof(text)) != 0) return -1;
    cursor = strrchr(text, ')');
    if (cursor == NULL) return -1;
    cursor++;
    while (*cursor == ' ') cursor++;
    if (*cursor == '\0') return -1;
    while (*cursor != '\0' && *cursor != ' ') cursor++;
    for (int field = 4; field <= 22; ++field) {
        char *end;
        while (*cursor == ' ') cursor++;
        errno = 0;
        value = strtoll(cursor, &end, 10);
        if (errno != 0 || end == cursor) return -1;
        cursor = end;
    }
    if (value <= 0) return -1;
    *uid = metadata.st_uid;
    *starttime = (unsigned long long)value;
    return 0;
}

static int source_identity_matches(void) {
    uid_t uid;
    unsigned long long starttime;
    return state.armed &&
           read_process_identity(state.pid, &uid, &starttime) == 0 &&
           uid == state.uid && starttime == state.starttime;
}

static int suppression_target(void) {
    long level = read_number(NICE_FILE);
    if (level < 0 || level > 40) level = 40;
    return level >= 40 ? 19 : (int)level - 20;
}

static size_t task_hash(pid_t tid) {
    uint32_t value = (uint32_t)tid;
    value ^= value >> 16;
    value *= 0x7feb352dU;
    value ^= value >> 15;
    return (size_t)value & (TASK_HASH_SIZE - 1);
}

static struct task_state *find_task(pid_t tid) {
    size_t slot = task_hash(tid);
    for (size_t probe = 0; probe < TASK_HASH_SIZE; ++probe) {
        uint16_t stored = state.task_slots[slot];
        if (stored == 0) return NULL;
        if (state.tasks[stored - 1].tid == tid) return &state.tasks[stored - 1];
        slot = (slot + 1) & (TASK_HASH_SIZE - 1);
    }
    return NULL;
}

static struct task_state *register_task(pid_t tid) {
    struct task_state *record = find_task(tid);
    uid_t uid;
    unsigned long long starttime;
    int target = state.target_nice;
    size_t slot;
    int original;
    if (read_process_identity(tid, &uid, &starttime) != 0 ||
        uid != state.uid)
        return NULL;
    if (record != NULL && record->starttime == starttime) {
        record->applied_nice = record->original_nice < target
                                   ? target
                                   : record->original_nice;
        return record;
    }
    errno = 0;
    original = getpriority(PRIO_PROCESS, (id_t)tid);
    if (errno != 0) return NULL;
    if (record != NULL) {
        record->starttime = starttime;
        record->original_nice = original;
        record->applied_nice = original < target ? target : original;
        record->original_affinity = state.active ? 0 : proc_get_affinity(tid);
        record->affinity_valid = record->original_affinity != 0;
        return record;
    }
    if (state.task_count >= MAX_TASKS) return NULL;
    record = &state.tasks[state.task_count];
    record->tid = tid;
    record->starttime = starttime;
    record->original_nice = original;
    record->applied_nice = original < target ? target : original;
    record->original_affinity = state.active ? 0 : proc_get_affinity(tid);
    record->affinity_valid = record->original_affinity != 0;
    slot = task_hash(tid);
    for (size_t probe = 0; probe < TASK_HASH_SIZE; ++probe) {
        if (state.task_slots[slot] == 0) {
            state.task_slots[slot] = (uint16_t)(state.task_count + 1);
            state.task_count++;
            return record;
        }
        slot = (slot + 1) & (TASK_HASH_SIZE - 1);
    }
    return NULL;
}

static int refresh_tasks(void) {
    char path[64];
    DIR *directory;
    struct dirent *entry;
    snprintf(path, sizeof(path), "/proc/%d/task", state.pid);
    directory = opendir(path);
    if (directory == NULL) return -1;
    while ((entry = readdir(directory)) != NULL) {
        char *end;
        long parsed;
        struct task_state *record;
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9') continue;
        parsed = strtol(entry->d_name, &end, 10);
        if (*end != '\0' || parsed <= 1 || parsed > INT32_MAX) continue;
        record = register_task((pid_t)parsed);
        if (record == NULL && state.task_count >= MAX_TASKS) {
            closedir(directory);
            return -1;
        }
    }
    closedir(directory);
    return state.task_count > 0 ? 0 : -1;
}

static int apply_task_nice(struct task_state *record) {
    uid_t uid;
    unsigned long long starttime;
    int current;
    if (read_process_identity(record->tid, &uid, &starttime) != 0 ||
        uid != state.uid || starttime != record->starttime)
        return 0;
    errno = 0;
    current = getpriority(PRIO_PROCESS, (id_t)record->tid);
    if (errno != 0 || current == record->applied_nice) return 0;
    return setpriority(PRIO_PROCESS, (id_t)record->tid,
                       record->applied_nice) == 0
               ? 1
               : 0;
}

static void apply_nice(void) {
    for (size_t i = 0; i < state.task_count; ++i) {
        (void)apply_task_nice(&state.tasks[i]);
    }
}

static void capture_known_baseline(void) {
    int target = state.target_nice;
    for (size_t i = 0; i < state.task_count; ++i) {
        struct task_state *record = &state.tasks[i];
        uint64_t affinity;
        int current;
        errno = 0;
        current = getpriority(PRIO_PROCESS, (id_t)record->tid);
        if (errno != 0) continue;
        affinity = proc_get_affinity(record->tid);
        if (affinity == 0) continue;
        record->original_nice = current;
        record->applied_nice = current < target ? target : current;
        record->original_affinity = affinity;
        record->affinity_valid = 1;
    }
}

static void restore_nice(int force) {
    for (size_t i = 0; i < state.task_count; ++i) {
        uid_t uid;
        unsigned long long starttime;
        int current;
        if (state.tasks[i].applied_nice == state.tasks[i].original_nice)
            continue;
        if (read_process_identity(state.tasks[i].tid, &uid, &starttime) != 0 ||
            uid != state.uid || starttime != state.tasks[i].starttime)
            continue;
        errno = 0;
        current = getpriority(PRIO_PROCESS, (id_t)state.tasks[i].tid);
        if (errno == 0 && (force || current == state.tasks[i].applied_nice)) {
            state.nice_restore_attempts++;
            if (setpriority(PRIO_PROCESS, (id_t)state.tasks[i].tid,
                            state.tasks[i].original_nice) == 0)
                state.nice_restore_successes++;
        }
    }
}

static void restore_affinity(void) {
    for (size_t i = 0; i < state.task_count; ++i) {
        struct task_state *record = &state.tasks[i];
        uid_t uid;
        unsigned long long starttime;
        if (!record->affinity_valid ||
            read_process_identity(record->tid, &uid, &starttime) != 0 ||
            uid != state.uid || starttime != record->starttime)
            continue;
        state.affinity_restore_attempts++;
        if (proc_set_affinity(record->tid, record->original_affinity) == 0)
            state.affinity_restore_successes++;
    }
}

static void publish_status(const char *reason) {
    char temporary[256];
    FILE *file;
    struct task_state *main_record = find_task(state.pid);
    int main_original_nice = main_record == NULL ? 0 : main_record->original_nice;
    unsigned long long main_original_affinity =
        main_record == NULL ? 0 : main_record->original_affinity;
    snprintf(temporary, sizeof(temporary), "%s.tmp", STATUS_PATH);
    file = fopen(temporary, "we");
    if (file == NULL) return;
    fprintf(file, "pid=%d\nuid=%u\npackage=%s\nstarttime=%llu\ntransition_id=%llu\ncompletion_pending=%d\narmed=%d\nactive=%d\ntrace_enabled=%d\ntasks=%zu\nreassertions=%lu\nmain_original_nice=%d\nmain_original_affinity=%llx\naffinity_restore_attempts=%lu\naffinity_restore_successes=%lu\nnice_restore_attempts=%lu\nnice_restore_successes=%lu\nreason=%s\n",
            state.pid, state.uid, state.package, state.starttime,
            (unsigned long long)accepted_transition_id,
            completion_transition_id != 0, state.armed, state.active,
            trace_enabled, state.task_count, state.reassertions,
            main_original_nice, main_original_affinity,
            state.affinity_restore_attempts,
            state.affinity_restore_successes,
            state.nice_restore_attempts, state.nice_restore_successes, reason);
    if (fclose(file) == 0) (void)rename(temporary, STATUS_PATH);
}

static int move_source_group(pid_t pid) {
    int cpuset_ok = write_pid(SOURCE_CPUSET_PROCS, pid) == 0;
    int cpuctl_ok = write_pid(SOURCE_CPUCTL_PROCS, pid) == 0;
    return cpuset_ok && cpuctl_ok ? 0 : -1;
}

static int move_source_task(pid_t tid) {
    int cpuset_ok = write_pid(SOURCE_CPUSET_TASKS, tid) == 0;
    int cpuctl_ok = write_pid(SOURCE_CPUCTL_TASKS, tid) == 0;
    return cpuset_ok && cpuctl_ok ? 0 : -1;
}

static void restore_minor(int preserve) {
    if (!state.original_minor_valid) return;
    if (preserve) (void)write_number(MINOR_WINDOW_NODE, state.original_minor);
    else if (read_number(MINOR_WINDOW_NODE) == (long)state.uid)
        (void)write_number(MINOR_WINDOW_NODE, 0);
}

static int arm_source(pid_t pid, uid_t uid, const char *package) {
    uid_t actual_uid;
    unsigned long long starttime;
    if (read_process_identity(pid, &actual_uid, &starttime) != 0 ||
        actual_uid != uid) return -1;
    if (state.active && (state.pid != pid || state.uid != uid ||
                         state.starttime != starttime)) {
        state.active = 0;
        (void)set_trace_enabled(0);
        if (source_identity_matches()) {
            restore_nice(0);
            restore_minor(0);
            (void)write_pid(BACKGROUND_CPUSET_PROCS, state.pid);
            (void)write_pid(BACKGROUND_CPUCTL_PROCS, state.pid);
        }
    }
    if (!state.armed || state.pid != pid || state.uid != uid ||
        state.starttime != starttime) {
        reset_guard_state();
        state.pid = pid;
        state.uid = uid;
        state.starttime = starttime;
        state.target_nice = suppression_target();
        if (package != NULL)
            snprintf(state.package, sizeof(state.package), "%s", package);
        state.original_minor = read_number(MINOR_WINDOW_NODE);
        state.original_minor_valid = state.original_minor >= 0;
        state.armed = 1;
        if (open_task_directory(pid) != 0) return -1;
    } else if (task_directory_fd < 0 && open_task_directory(pid) != 0) {
        return -1;
    } else if (package != NULL && package[0] != '\0') {
        snprintf(state.package, sizeof(state.package), "%s", package);
        state.target_nice = suppression_target();
    }
    if (refresh_tasks() != 0) return -1;
    publish_status("armed");
    return 0;
}

static int activate_source(pid_t pid, uid_t uid, const char *package,
                           const char *reason) {
    if (!state.armed || state.pid != pid || state.uid != uid) {
        if (arm_source(pid, uid, package) != 0) return -1;
    } else if (state.active) {
        (void)refresh_tasks();
    }
    if (!source_identity_matches() || state.task_count == 0) return -1;
    /* Capture exactly once at the inactive -> active transaction boundary.
     * A same-source handoff can arrive while the return animation is still
     * suppressed; recapturing there would turn the suppressed state into the
     * restoration baseline. */
    if (!state.active) capture_known_baseline();
    state.active = 1;
    if (set_trace_enabled(1) != 0) {
        state.active = 0;
        return -1;
    }
    if (read_number(MINOR_WINDOW_NODE) == (long)uid)
        (void)write_number(MINOR_WINDOW_NODE, 0);
    if (move_source_group(pid) != 0) {
        state.active = 0;
        (void)set_trace_enabled(0);
        return -1;
    }
    apply_nice();
    publish_status(reason);
    return 0;
}

static int complete_source(uint64_t transition_id, const char *reason) {
    if (transition_id != accepted_transition_id || !state.armed) return 0;
    cancel_completion_timer();
    state.active = 0;
    (void)set_trace_enabled(0);
    if (source_identity_matches()) {
        (void)write_pid(TOP_CPUSET_PROCS, state.pid);
        (void)write_pid(TOP_CPUCTL_PROCS, state.pid);
        restore_affinity();
        restore_nice(1);
        restore_minor(1);
    }
    publish_status(reason);
    return 0;
}

static int schedule_completion(uint64_t transition_id, unsigned delay_ms) {
    struct itimerspec timer = {0};
    if (!state.active || transition_id != accepted_transition_id ||
        completion_timer_fd < 0)
        return -1;
    if (delay_ms < 100) delay_ms = 100;
    if (delay_ms > 5000) delay_ms = 5000;
    timer.it_value.tv_sec = delay_ms / 1000;
    timer.it_value.tv_nsec = (long)(delay_ms % 1000) * 1000000L;
    completion_transition_id = transition_id;
    if (timerfd_settime(completion_timer_fd, 0, &timer, NULL) != 0) {
        completion_transition_id = 0;
        return -1;
    }
    publish_status("completion-scheduled");
    return 0;
}

static void reassert_source(pid_t tid) {
    int corrected = 0;
    struct task_state *record;
    if (!state.active) return;
    if (!source_identity_matches()) {
        state.active = 0;
        (void)set_trace_enabled(0);
        reset_guard_state();
        publish_status("source-identity-ended");
        return;
    }
    record = find_task(tid);
    if (record == NULL) {
        if (!task_belongs_to_source(tid)) return;
        record = register_task(tid);
        if (record == NULL) return;
    }
    /* drain_ring only dispatches events whose destination is outside the
     * source group, so no /proc cgroup read is needed here. */
    if (tid == state.pid) {
        if (move_source_group(state.pid) == 0) {
            corrected = 1;
        }
    } else if (move_source_task(tid) == 0) {
        corrected = 1;
    }
    if (apply_task_nice(record) > 0) corrected = 1;
    if (corrected) {
        state.reassertions++;
    }
}

static int release_source(pid_t pid, int top_app, int preserve_minor) {
    if (!state.armed || state.pid != pid) return 0;
    cancel_completion_timer();
    state.active = 0;
    (void)set_trace_enabled(0);
    if (source_identity_matches()) {
        if (top_app) {
            (void)write_pid(TOP_CPUSET_PROCS, pid);
            (void)write_pid(TOP_CPUCTL_PROCS, pid);
            restore_affinity();
        } else {
            (void)write_pid(BACKGROUND_CPUSET_PROCS, pid);
            (void)write_pid(BACKGROUND_CPUCTL_PROCS, pid);
        }
        restore_nice(top_app);
        restore_minor(preserve_minor);
    }
    publish_status(top_app ? "restored-top" : "released-background");
    reset_guard_state();
    publish_status("idle");
    return 0;
}

static int read_process_package(pid_t pid, char *package, size_t size) {
    char path[64];
    int fd;
    ssize_t length;
    snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    length = read(fd, package, size - 1);
    close(fd);
    if (length <= 0) return -1;
    package[length] = '\0';
    return package[0] != '\0' ? 0 : -1;
}

static int find_package_process(const char *package, pid_t *pid, uid_t *uid) {
    DIR *directory = opendir("/proc");
    struct dirent *entry;
    pid_t selected = 0;
    uid_t selected_uid = 0;
    if (directory == NULL || package == NULL || package[0] == '\0') return -1;
    while ((entry = readdir(directory)) != NULL) {
        char *end;
        long parsed;
        char live_package[PACKAGE_LENGTH];
        uid_t live_uid;
        unsigned long long starttime;
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9') continue;
        errno = 0;
        parsed = strtol(entry->d_name, &end, 10);
        if (errno != 0 || *end != '\0' || parsed <= 1 || parsed > INT32_MAX)
            continue;
        if (read_process_package((pid_t)parsed, live_package,
                                 sizeof(live_package)) != 0 ||
            strcmp(live_package, package) != 0 ||
            read_process_identity((pid_t)parsed, &live_uid, &starttime) != 0 ||
            live_uid < 1000)
            continue;
        if (selected == 0 || parsed < selected) {
            selected = (pid_t)parsed;
            selected_uid = live_uid;
        }
    }
    closedir(directory);
    if (selected == 0) return -1;
    *pid = selected;
    *uid = selected_uid;
    return 0;
}

static int parse_transition(const char *text, uint64_t *transition_id,
                            const char **rest) {
    char *end;
    unsigned long long parsed;
    errno = 0;
    parsed = strtoull(text, &end, 10);
    if (errno != 0 || end == text || parsed == 0) return -1;
    while (*end == ' ') end++;
    *transition_id = (uint64_t)parsed;
    if (rest != NULL) *rest = end;
    return 0;
}

static int begin_transition(uint64_t transition_id) {
    if (!state.armed || transition_id < accepted_transition_id) return -1;
    accepted_transition_id = transition_id;
    cancel_completion_timer();
    if (state.active) {
        publish_status("transition-extended");
        return 0;
    }
    return activate_source(state.pid, state.uid, state.package,
                           "transition-active");
}

static int adopt_package(uint64_t transition_id, const char *package,
                         int activate) {
    pid_t pid;
    uid_t uid;
    if (transition_id < accepted_transition_id ||
        find_package_process(package, &pid, &uid) != 0)
        return -1;
    if (!activate && state.active)
        (void)release_source(state.pid, 0, 0);
    accepted_transition_id = transition_id;
    cancel_completion_timer();
    if (state.armed && state.pid == pid && state.uid == uid &&
        strcmp(state.package, package) == 0)
        return activate ? activate_source(pid, uid, package, "handoff-same") : 0;
    if (arm_source(pid, uid, package) != 0) return -1;
    return activate ? activate_source(pid, uid, package, "handoff-active") : 0;
}

static int replace_current(pid_t pid, uid_t uid, const char *package) {
    int was_active;
    if (!state.armed || strcmp(state.package, package) != 0 || state.uid != uid)
        return -1;
    if (source_identity_matches() && state.pid != pid) return -1;
    was_active = state.active;
    if (arm_source(pid, uid, package) != 0) return -1;
    return was_active ? activate_source(pid, uid, package, "process-replaced") : 0;
}

static int parse_pid_uid(const char *text, pid_t *pid, uid_t *uid,
                         const char **rest) {
    char *end;
    unsigned long parsed_uid;
    long parsed_pid = strtol(text, &end, 10);
    if (end == text || parsed_pid <= 1 || parsed_pid > INT32_MAX) return -1;
    while (*end == ' ') end++;
    parsed_uid = strtoul(end, &end, 10);
    if (parsed_uid < 1000 || parsed_uid > UINT32_MAX) return -1;
    while (*end == ' ') end++;
    *pid = (pid_t)parsed_pid;
    *uid = (uid_t)parsed_uid;
    if (rest != NULL) *rest = end;
    return 0;
}

static void handle_command(char *command) {
    pid_t pid;
    uid_t uid;
    uint64_t transition_id;
    const char *rest;
    char *arguments = strchr(command, ' ');
    if (arguments != NULL) {
        *arguments++ = '\0';
        while (*arguments == ' ') arguments++;
    }
    if (strcmp(command, "arm") == 0 && arguments != NULL &&
        parse_pid_uid(arguments, &pid, &uid, &rest) == 0 && rest[0] != '\0' &&
        !state.active) {
        (void)arm_source(pid, uid, rest);
    } else if (strcmp(command, "enter") == 0 && arguments != NULL &&
               parse_transition(arguments, &transition_id, NULL) == 0) {
        (void)begin_transition(transition_id);
    } else if (strcmp(command, "handoff") == 0 && arguments != NULL &&
               parse_transition(arguments, &transition_id, &rest) == 0 &&
               rest[0] != '\0') {
        (void)adopt_package(transition_id, rest, 1);
    } else if (strcmp(command, "adopt") == 0 && arguments != NULL &&
               parse_transition(arguments, &transition_id, &rest) == 0 &&
               rest[0] != '\0') {
        (void)adopt_package(transition_id, rest, 0);
    } else if (strcmp(command, "complete") == 0 && arguments != NULL &&
               parse_transition(arguments, &transition_id, &rest) == 0) {
        unsigned long delay = strtoul(rest, NULL, 10);
        (void)schedule_completion(transition_id, (unsigned)delay);
    } else if (strcmp(command, "replace-current") == 0 && arguments != NULL &&
               parse_pid_uid(arguments, &pid, &uid, &rest) == 0 &&
               rest[0] != '\0') {
        (void)replace_current(pid, uid, rest);
    } else if (strcmp(command, "restore-top") == 0 && arguments != NULL) {
        pid = (pid_t)strtol(arguments, NULL, 10);
        (void)release_source(pid, 1, 1);
    } else if (strcmp(command, "release-background") == 0 && arguments != NULL) {
        pid = (pid_t)strtol(arguments, NULL, 10);
        (void)release_source(pid, 0, 0);
    } else if (strcmp(command, "disable") == 0) {
        if (state.armed) (void)release_source(state.pid, 1, 1);
        accepted_transition_id = 0;
    } else if (strcmp(command, "reset-top") == 0) {
        if (state.armed) (void)release_source(state.pid, 1, 1);
        accepted_transition_id = 0;
    } else if (strcmp(command, "stop") == 0) {
        if (state.armed) (void)release_source(state.pid, 1, 1);
        running = 0;
    }
}

static int perf_event_open(struct perf_event_attr *attribute, int cpu) {
    return (int)syscall(__NR_perf_event_open, attribute, -1, cpu, -1,
                        PERF_FLAG_FD_CLOEXEC);
}

static int read_trace_offsets(size_t *pid_offset, size_t *path_loc_offset) {
    char text[8192];
    char *line;
    int found_pid = 0;
    int found_path = 0;
    if (read_text(TRACE_FORMAT_PATH, text, sizeof(text)) != 0) return -1;
    line = strtok(text, "\n");
    while (line != NULL) {
        char *field = strstr(line, "field:");
        char *offset_text = strstr(line, "offset:");
        if (field != NULL && offset_text != NULL && strstr(field, " pid;") != NULL) {
            char *end;
            unsigned long parsed = strtoul(offset_text + 7, &end, 10);
            if (end != offset_text + 7 && parsed <= 4096) {
                *pid_offset = (size_t)parsed;
                found_pid = 1;
            }
        }
        if (field != NULL && offset_text != NULL && strstr(field, " dst_path;") != NULL) {
            char *end;
            unsigned long parsed = strtoul(offset_text + 7, &end, 10);
            if (end != offset_text + 7 && parsed <= 4096) {
                *path_loc_offset = (size_t)parsed;
                found_path = 1;
            }
        }
        line = strtok(NULL, "\n");
    }
    return found_pid && found_path ? 0 : -1;
}

static int trace_destination_is_source(const unsigned char *raw, size_t raw_size) {
    uint32_t location;
    size_t offset;
    size_t length;
    size_t expected = strlen(SOURCE_GROUP);
    if (trace_path_loc_offset + sizeof(location) > raw_size) return 0;
    memcpy(&location, raw + trace_path_loc_offset, sizeof(location));
    offset = location & 0xffffU;
    length = location >> 16;
    if (length == 0 || offset > raw_size || length > raw_size - offset) return 0;
    if (length > 0 && raw[offset + length - 1] == '\0') length--;
    return length == expected && memcmp(raw + offset, SOURCE_GROUP, expected) == 0;
}

static int set_trace_enabled(int enabled) {
    int failed = 0;
    if (trace_enabled == enabled) return 0;
    for (int i = 0; i < trace_ring_count; ++i) {
        unsigned long request = enabled ? PERF_EVENT_IOC_ENABLE : PERF_EVENT_IOC_DISABLE;
        if (ioctl(trace_rings[i].fd, request, 0) != 0) failed = 1;
        if (!enabled) (void)ioctl(trace_rings[i].fd, PERF_EVENT_IOC_RESET, 0);
    }
    if (failed) {
        if (enabled) {
            for (int i = 0; i < trace_ring_count; ++i)
                (void)ioctl(trace_rings[i].fd, PERF_EVENT_IOC_DISABLE, 0);
        }
        return -1;
    }
    trace_enabled = enabled;
    return 0;
}

static int open_trace_rings(struct perf_ring *rings, int maximum) {
    long trace_id = read_number(TRACE_ID_PATH);
    long page_size = sysconf(_SC_PAGESIZE);
    long cpus = sysconf(_SC_NPROCESSORS_CONF);
    int count = 0;
    if (trace_id <= 0 || page_size <= 0 || cpus <= 0 ||
        read_trace_offsets(&trace_pid_offset, &trace_path_loc_offset) != 0) return -1;
    if (cpus > maximum) cpus = maximum;
    for (int cpu = 0; cpu < cpus; ++cpu) {
        struct perf_event_attr attribute;
        int fd;
        void *mapping;
        memset(&attribute, 0, sizeof(attribute));
        attribute.type = PERF_TYPE_TRACEPOINT;
        attribute.size = sizeof(attribute);
        attribute.config = (uint64_t)trace_id;
        attribute.sample_period = 1;
        attribute.sample_type = PERF_SAMPLE_RAW;
        attribute.wakeup_events = 1;
        attribute.disabled = 1;
        fd = perf_event_open(&attribute, cpu);
        if (fd < 0) continue;
        mapping = mmap(NULL, (size_t)page_size * (PERF_PAGES + 1),
                       PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (mapping == MAP_FAILED) {
            close(fd);
            continue;
        }
        rings[count].fd = fd;
        rings[count].mapping = mapping;
        rings[count].mapping_size = (size_t)page_size * (PERF_PAGES + 1);
        rings[count].data_size = (size_t)page_size * PERF_PAGES;
        count++;
    }
    return count > 0 ? count : -1;
}

static void copy_ring_bytes(const struct perf_ring *ring, uint64_t position,
                            void *destination, size_t length) {
    struct perf_event_mmap_page *metadata = ring->mapping;
    unsigned char *data = (unsigned char *)ring->mapping + metadata->data_offset;
    size_t offset = (size_t)(position % ring->data_size);
    size_t first = ring->data_size - offset;
    if (first > length) first = length;
    memcpy(destination, data + offset, first);
    if (first < length)
        memcpy((unsigned char *)destination + first, data, length - first);
}

static void drain_ring(struct perf_ring *ring) {
    struct perf_event_mmap_page *metadata = ring->mapping;
    uint64_t head = __atomic_load_n(&metadata->data_head, __ATOMIC_ACQUIRE);
    uint64_t tail = metadata->data_tail;
    unsigned char record[1024];
    while (tail < head) {
        struct perf_event_header header;
        copy_ring_bytes(ring, tail, &header, sizeof(header));
        if (header.size < sizeof(header) || header.size > sizeof(record)) {
            tail += header.size >= sizeof(header) ? header.size : sizeof(header);
            continue;
        }
        copy_ring_bytes(ring, tail, record, header.size);
        if (header.type == PERF_RECORD_SAMPLE && header.size >= 12) {
            uint32_t raw_size;
            unsigned char *raw = record + sizeof(header) + sizeof(raw_size);
            memcpy(&raw_size, record + sizeof(header), sizeof(raw_size));
            if (raw_size >= trace_pid_offset + sizeof(int) &&
                sizeof(header) + sizeof(raw_size) + raw_size <= header.size) {
                int event_pid;
                memcpy(&event_pid, raw + trace_pid_offset, sizeof(event_pid));
                if (state.active && !trace_destination_is_source(raw, raw_size) &&
                    (event_pid == state.pid || find_task((pid_t)event_pid) != NULL ||
                     task_belongs_to_source((pid_t)event_pid)))
                    reassert_source((pid_t)event_pid);
            }
        }
        tail += header.size;
    }
    metadata->data_tail = tail;
}

static int create_socket(void) {
    struct sockaddr_un address;
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", SOCKET_PATH);
    unlink(SOCKET_PATH);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }
    chmod(SOCKET_PATH, 0600);
    return fd;
}

static int send_command(int argc, char **argv) {
    struct sockaddr_un address;
    char command[256] = "";
    int fd;
    size_t used = 0;
    for (int i = 1; i < argc; ++i) {
        int written = snprintf(command + used, sizeof(command) - used, "%s%s",
                               i == 1 ? "" : " ", argv[i]);
        if (written < 0 || (size_t)written >= sizeof(command) - used) return 2;
        used += (size_t)written;
    }
    fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return 3;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", SOCKET_PATH);
    if (sendto(fd, command, used + 1, 0, (struct sockaddr *)&address,
               sizeof(address)) < 0) {
        close(fd);
        return 4;
    }
    close(fd);
    return 0;
}

static void handle_signal(int signal_number) {
    (void)signal_number;
    running = 0;
}

static void pin_controller_to_secondary_cpu(void) {
    char text[512];
    unsigned long long masks[9];
    cpu_set_t set;
    unsigned long long selected;
    int cpu = 0;
    if (read_text(TOPOLOGY_FILE, text, sizeof(text)) != 0 ||
        sscanf(text, "%llx %llx %llx %llx %llx %llx %llx %llx %llx",
               &masks[0], &masks[1], &masks[2], &masks[3], &masks[4],
               &masks[5], &masks[6], &masks[7], &masks[8]) != 9)
        return;
    selected = masks[6] & (~masks[6] + 1);
    if (selected == 0) return;
    while (cpu < CPU_SETSIZE && cpu < 64 &&
           (selected & (1ULL << (unsigned)cpu)) == 0)
        cpu++;
    if (cpu >= CPU_SETSIZE || cpu >= 64) return;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    (void)sched_setaffinity(0, sizeof(set), &set);
    (void)setpriority(PRIO_PROCESS, (id_t)getpid(), -10);
}

static int daemon_main(void) {
    struct pollfd pollfds[66];
    int socket_fd;
    setvbuf(stdout, NULL, _IOLBF, 0);
    pin_controller_to_secondary_cpu();
    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);
    socket_fd = create_socket();
    if (socket_fd < 0) return 10;
    completion_timer_fd = timerfd_create(CLOCK_MONOTONIC,
                                         TFD_CLOEXEC | TFD_NONBLOCK);
    if (completion_timer_fd < 0) {
        unlink(SOCKET_PATH);
        close(socket_fd);
        return 11;
    }
    trace_ring_count = open_trace_rings(trace_rings, 64);
    if (trace_ring_count < 0) {
        unlink(SOCKET_PATH);
        close(socket_fd);
        close(completion_timer_fd);
        fprintf(stderr, "source-guard: cgroup_attach_task tracepoint is unavailable\n");
        return 12;
    }
    pollfds[0].fd = socket_fd;
    pollfds[0].events = POLLIN;
    pollfds[1].fd = completion_timer_fd;
    pollfds[1].events = POLLIN;
    for (int i = 0; i < trace_ring_count; ++i) {
        pollfds[i + 2].fd = trace_rings[i].fd;
        pollfds[i + 2].events = POLLIN;
    }
    publish_status("idle");
    printf("source-guard ready trace_rings=%d\n", trace_ring_count);
    while (running) {
        int ready = poll(pollfds, (nfds_t)trace_ring_count + 2, -1);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if ((pollfds[0].revents & POLLIN) != 0) {
            char command[256];
            ssize_t length = recv(socket_fd, command, sizeof(command) - 1, 0);
            if (length > 0) {
                command[length] = '\0';
                handle_command(command);
            }
        }
        if ((pollfds[1].revents & POLLIN) != 0) {
            uint64_t expirations;
            if (read(completion_timer_fd, &expirations, sizeof(expirations)) ==
                    (ssize_t)sizeof(expirations) &&
                completion_transition_id == accepted_transition_id) {
                uint64_t completed = completion_transition_id;
                completion_transition_id = 0;
                (void)complete_source(completed, "visual-complete");
            }
        }
        for (int i = 0; i < trace_ring_count; ++i) {
            if ((pollfds[i + 2].revents & POLLIN) != 0) drain_ring(&trace_rings[i]);
        }
    }
    if (state.armed) (void)release_source(state.pid, 1, 1);
    for (int i = 0; i < trace_ring_count; ++i) {
        munmap(trace_rings[i].mapping, trace_rings[i].mapping_size);
        close(trace_rings[i].fd);
    }
    unlink(SOCKET_PATH);
    unlink(STATUS_PATH);
    close(socket_fd);
    close(completion_timer_fd);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "daemon") == 0) return daemon_main();
    if (argc >= 2) return send_command(argc, argv);
    fprintf(stderr, "usage: %s daemon | arm PID UID PACKAGE | enter ID | handoff ID PACKAGE | adopt ID PACKAGE | complete ID DELAY_MS | replace-current PID UID PACKAGE | restore-top PID | release-background PID | reset-top | disable | stop\n",
            argv[0]);
    return 1;
}
