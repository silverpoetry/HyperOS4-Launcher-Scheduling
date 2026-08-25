#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <poll.h>
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
#define MINOR_WINDOW_NODE "/sys/module/metis/parameters/minor_window_app"
#define SOURCE_GROUP "/hyperos4-source"
#define MAX_TASKS 4096
#define TASK_HASH_SIZE 8192
#define PERF_PAGES 8

struct task_nice {
    pid_t tid;
    int original;
    int applied;
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
    struct task_nice tasks[MAX_TASKS];
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

static int set_trace_enabled(int enabled);

static long long monotonic_us(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (long long)value.tv_sec * 1000000LL + value.tv_nsec / 1000LL;
}

static void log_line(const char *action, long long elapsed_us) {
    printf("source-guard action=%s pid=%d uid=%u active=%d tasks=%zu reassertions=%lu elapsed_us=%lld\n",
           action, state.pid, state.uid, state.active, state.task_count,
           state.reassertions, elapsed_us);
    fflush(stdout);
}

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

static struct task_nice *find_task(pid_t tid) {
    size_t slot = task_hash(tid);
    for (size_t probe = 0; probe < TASK_HASH_SIZE; ++probe) {
        uint16_t stored = state.task_slots[slot];
        if (stored == 0) return NULL;
        if (state.tasks[stored - 1].tid == tid) return &state.tasks[stored - 1];
        slot = (slot + 1) & (TASK_HASH_SIZE - 1);
    }
    return NULL;
}

static struct task_nice *register_task(pid_t tid) {
    struct task_nice *record = find_task(tid);
    int target = suppression_target();
    size_t slot;
    int original;
    if (record != NULL) {
        record->applied = record->original < target ? target : record->original;
        return record;
    }
    if (state.task_count >= MAX_TASKS) return NULL;
    errno = 0;
    original = getpriority(PRIO_PROCESS, (id_t)tid);
    if (errno != 0) return NULL;
    record = &state.tasks[state.task_count];
    record->tid = tid;
    record->original = original;
    record->applied = original < target ? target : original;
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
        struct task_nice *record;
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

static int apply_task_nice(struct task_nice *record) {
    int current;
    errno = 0;
    current = getpriority(PRIO_PROCESS, (id_t)record->tid);
    if (errno != 0 || current == record->applied) return 0;
    return setpriority(PRIO_PROCESS, (id_t)record->tid, record->applied) == 0 ? 1 : 0;
}

static void apply_nice(void) {
    for (size_t i = 0; i < state.task_count; ++i) {
        (void)apply_task_nice(&state.tasks[i]);
    }
}

static void restore_nice(void) {
    for (size_t i = 0; i < state.task_count; ++i) {
        int current;
        if (state.tasks[i].applied == state.tasks[i].original) continue;
        errno = 0;
        current = getpriority(PRIO_PROCESS, (id_t)state.tasks[i].tid);
        if (errno == 0 && current == state.tasks[i].applied)
            (void)setpriority(PRIO_PROCESS, (id_t)state.tasks[i].tid,
                              state.tasks[i].original);
    }
}

static void publish_status(const char *reason) {
    char temporary[256];
    FILE *file;
    snprintf(temporary, sizeof(temporary), "%s.tmp", STATUS_PATH);
    file = fopen(temporary, "we");
    if (file == NULL) return;
    fprintf(file, "pid=%d\nuid=%u\nstarttime=%llu\narmed=%d\nactive=%d\ntrace_enabled=%d\ntasks=%zu\nreassertions=%lu\nreason=%s\n",
            state.pid, state.uid, state.starttime, state.armed, state.active,
            trace_enabled, state.task_count, state.reassertions, reason);
    if (fclose(file) == 0) (void)rename(temporary, STATUS_PATH);
}

static int task_in_source_groups(pid_t tid) {
    char path[96];
    char text[4096];
    int cpuset = 0;
    int cpu = 0;
    char *line;
    snprintf(path, sizeof(path), "/proc/%d/task/%d/cgroup", state.pid, tid);
    if (read_text(path, text, sizeof(text)) != 0) return -1;
    line = strtok(text, "\n");
    while (line != NULL) {
        if (strstr(line, ":cpuset:" SOURCE_GROUP) != NULL) cpuset = 1;
        if (strstr(line, ":cpu:" SOURCE_GROUP) != NULL) cpu = 1;
        line = strtok(NULL, "\n");
    }
    return cpuset && cpu;
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

static int arm_source(pid_t pid, uid_t uid) {
    long long started = monotonic_us();
    uid_t actual_uid;
    unsigned long long starttime;
    if (read_process_identity(pid, &actual_uid, &starttime) != 0 ||
        actual_uid != uid) return -1;
    if (state.active && (state.pid != pid || state.uid != uid ||
                         state.starttime != starttime)) {
        state.active = 0;
        (void)set_trace_enabled(0);
        if (source_identity_matches()) {
            restore_nice();
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
        state.original_minor = read_number(MINOR_WINDOW_NODE);
        state.original_minor_valid = state.original_minor >= 0;
        state.armed = 1;
        if (open_task_directory(pid) != 0) return -1;
    } else if (task_directory_fd < 0 && open_task_directory(pid) != 0) {
        return -1;
    }
    (void)refresh_tasks();
    publish_status("armed");
    log_line("arm", monotonic_us() - started);
    return 0;
}

static int activate_source(pid_t pid, uid_t uid, const char *reason) {
    long long started = monotonic_us();
    if (!state.armed || state.pid != pid || state.uid != uid) {
        if (arm_source(pid, uid) != 0) return -1;
    } else {
        (void)refresh_tasks();
    }
    if (!source_identity_matches()) return -1;
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
    log_line("activate", monotonic_us() - started);
    return 0;
}

static void reassert_source(pid_t tid) {
    int group_state;
    int corrected = 0;
    struct task_nice *record;
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
    group_state = task_in_source_groups(tid);
    if (group_state < 0) return;
    if (group_state == 0) {
        if (tid == state.pid) {
            (void)refresh_tasks();
            if (move_source_group(state.pid) == 0) {
                apply_nice();
                corrected = 1;
            }
        } else if (move_source_task(tid) == 0) {
            corrected = 1;
        }
    }
    if (apply_task_nice(record) > 0) corrected = 1;
    if (corrected) {
        state.reassertions++;
    }
}

static int release_source(pid_t pid, int top_app, int preserve_minor) {
    long long started = monotonic_us();
    if (!state.armed || state.pid != pid) return 0;
    state.active = 0;
    (void)set_trace_enabled(0);
    if (source_identity_matches()) {
        restore_nice();
        restore_minor(preserve_minor);
        if (top_app) {
            (void)write_pid(TOP_CPUSET_PROCS, pid);
            (void)write_pid(TOP_CPUCTL_PROCS, pid);
        } else {
            (void)write_pid(BACKGROUND_CPUSET_PROCS, pid);
            (void)write_pid(BACKGROUND_CPUCTL_PROCS, pid);
        }
    }
    publish_status(top_app ? "restored-top" : "released-background");
    log_line(top_app ? "restore-top" : "release-background",
             monotonic_us() - started);
    reset_guard_state();
    publish_status("idle");
    return 0;
}

static int parse_pid_uid(const char *text, pid_t *pid, uid_t *uid) {
    char *end;
    unsigned long parsed_uid;
    long parsed_pid = strtol(text, &end, 10);
    if (end == text || parsed_pid <= 1 || parsed_pid > INT32_MAX) return -1;
    while (*end == ' ') end++;
    parsed_uid = strtoul(end, &end, 10);
    if (parsed_uid < 1000 || parsed_uid > UINT32_MAX) return -1;
    *pid = (pid_t)parsed_pid;
    *uid = (uid_t)parsed_uid;
    return 0;
}

static void handle_command(char *command) {
    pid_t pid;
    uid_t uid;
    char *arguments = strchr(command, ' ');
    if (arguments != NULL) {
        *arguments++ = '\0';
        while (*arguments == ' ') arguments++;
    }
    if (strcmp(command, "arm") == 0 && arguments != NULL &&
        parse_pid_uid(arguments, &pid, &uid) == 0) {
        (void)arm_source(pid, uid);
    } else if (strcmp(command, "activate") == 0 && arguments != NULL &&
               parse_pid_uid(arguments, &pid, &uid) == 0) {
        (void)activate_source(pid, uid, "command");
    } else if (strcmp(command, "restore-top") == 0 && arguments != NULL) {
        pid = (pid_t)strtol(arguments, NULL, 10);
        (void)release_source(pid, 1, 1);
    } else if (strcmp(command, "release-background") == 0 && arguments != NULL) {
        pid = (pid_t)strtol(arguments, NULL, 10);
        (void)release_source(pid, 0, 0);
    } else if (strcmp(command, "disable") == 0) {
        if (state.armed) (void)release_source(state.pid, 0, 0);
    } else if (strcmp(command, "stop") == 0) {
        if (state.armed) (void)release_source(state.pid, 0, 0);
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

static int daemon_main(void) {
    struct pollfd pollfds[65];
    int socket_fd;
    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);
    socket_fd = create_socket();
    if (socket_fd < 0) return 10;
    trace_ring_count = open_trace_rings(trace_rings, 64);
    if (trace_ring_count < 0) {
        unlink(SOCKET_PATH);
        close(socket_fd);
        fprintf(stderr, "source-guard: cgroup_attach_task tracepoint is unavailable\n");
        return 11;
    }
    pollfds[0].fd = socket_fd;
    pollfds[0].events = POLLIN;
    for (int i = 0; i < trace_ring_count; ++i) {
        pollfds[i + 1].fd = trace_rings[i].fd;
        pollfds[i + 1].events = POLLIN;
    }
    publish_status("idle");
    printf("source-guard ready trace_rings=%d\n", trace_ring_count);
    while (running) {
        int ready = poll(pollfds, (nfds_t)trace_ring_count + 1, -1);
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
        for (int i = 0; i < trace_ring_count; ++i) {
            if ((pollfds[i + 1].revents & POLLIN) != 0) drain_ring(&trace_rings[i]);
        }
    }
    if (state.armed) (void)release_source(state.pid, 0, 0);
    for (int i = 0; i < trace_ring_count; ++i) {
        munmap(trace_rings[i].mapping, trace_rings[i].mapping_size);
        close(trace_rings[i].fd);
    }
    unlink(SOCKET_PATH);
    unlink(STATUS_PATH);
    close(socket_fd);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "daemon") == 0) return daemon_main();
    if (argc >= 2) return send_command(argc, argv);
    fprintf(stderr, "usage: %s daemon | arm PID UID | activate PID UID | restore-top PID | release-background PID | disable | stop\n",
            argv[0]);
    return 1;
}
