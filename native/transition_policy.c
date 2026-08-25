#define _GNU_SOURCE

#include "transition_policy.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum managed_class {
    MANAGED_NONE,
    LAUNCHER_UI,
    LAUNCHER_RUST,
    LAUNCHER_RASTER,
    LAUNCHER_RESMGR,
    LAUNCHER_FENCE,
    SYSTEMUI_CRITICAL,
    SYSTEMUI_MAINTENANCE,
    SYSTEM_SERVER_CRITICAL,
    SYSTEM_SERVER_SNAPSHOT,
};

static uint64_t placement_mask(const struct transition_policy *policy,
                               int placement) {
    if (placement < 1 || placement > POLICY_MASK_COUNT) return 0;
    return policy->config.masks[placement - 1];
}

static enum managed_class classify_launcher(const char *name) {
    if (strcmp(name, "1.raster") == 0) return LAUNCHER_RASTER;
    if (strcmp(name, "1.ui") == 0) return LAUNCHER_UI;
    if (strcmp(name, "rt-launcher-mai") == 0) return LAUNCHER_RUST;
    if (strcmp(name, "IplrVkResMgr") == 0) return LAUNCHER_RESMGR;
    if (strcmp(name, "IplrVkFenceWait") == 0) return LAUNCHER_FENCE;
    return MANAGED_NONE;
}

static enum managed_class classify_systemui(pid_t pid, pid_t tid,
                                             const char *name) {
    if (tid == pid || strcmp(name, "RenderThread") == 0 ||
        strcmp(name, "wmshell.main") == 0 ||
        strcmp(name, "GPU completion") == 0 ||
        strcmp(name, "RE Completion") == 0)
        return SYSTEMUI_CRITICAL;
    if (strcmp(name, "HeapTaskDaemon") == 0 ||
        strcmp(name, "FinalizerDaemon") == 0 ||
        strncmp(name, "FinalizerWatchd", 15) == 0 ||
        strncmp(name, "ReferenceQueueD", 15) == 0 ||
        strcmp(name, "Jit thread pool") == 0 ||
        strcmp(name, "Profile Saver") == 0)
        return SYSTEMUI_MAINTENANCE;
    return MANAGED_NONE;
}

static enum managed_class classify_system_server(const char *name) {
    if (strcmp(name, "android.anim") == 0 ||
        strcmp(name, "android.display") == 0)
        return SYSTEM_SERVER_CRITICAL;
    if (strncmp(name, "TaskSnapshot", 12) == 0)
        return SYSTEM_SERVER_SNAPSHOT;
    return MANAGED_NONE;
}

static struct policy_task *find_task(struct transition_policy *policy,
                                     pid_t tid,
                                     unsigned long long start_time) {
    for (size_t i = 0; i < policy->task_count; ++i)
        if (policy->tasks[i].tid == tid &&
            policy->tasks[i].start_time == start_time)
            return &policy->tasks[i];
    return NULL;
}

static void configure_target(struct transition_policy *policy,
                             struct policy_task *record,
                             enum managed_class thread_class) {
    int placement = policy->config.launcher_placement;
    uint32_t clamp = 0;
    record->affinity_managed = 1;
    record->clamp_managed = 0;
    record->transient = thread_class >= SYSTEMUI_CRITICAL;
    record->managed_class = thread_class;
    switch (thread_class) {
        case LAUNCHER_RASTER:
            placement = policy->config.raster_placement;
            clamp = policy->config.raster_min;
            record->clamp_managed = 1;
            break;
        case LAUNCHER_UI:
            clamp = policy->config.ui_min;
            record->clamp_managed = 1;
            break;
        case LAUNCHER_RUST:
            clamp = policy->config.rust_min;
            record->clamp_managed = 1;
            break;
        case LAUNCHER_RESMGR:
            placement = policy->config.resmgr_placement;
            clamp = policy->config.resmgr_min;
            record->clamp_managed = 1;
            break;
        case LAUNCHER_FENCE:
            placement = policy->config.fence_placement;
            break;
        case SYSTEMUI_CRITICAL:
            placement = policy->config.systemui_critical_placement;
            break;
        case SYSTEMUI_MAINTENANCE:
            placement = policy->config.systemui_maintenance_placement;
            break;
        case SYSTEM_SERVER_CRITICAL:
            placement = policy->config.system_server_critical_placement;
            break;
        case SYSTEM_SERVER_SNAPSHOT:
            placement = policy->config.system_server_snapshot_placement;
            break;
        default:
            record->affinity_managed = 0;
            return;
    }
    record->target_mask = placement_mask(policy, placement);
    record->target_clamp.minimum = clamp;
    record->target_clamp.maximum = 1024;
}

static int register_task(struct transition_policy *policy, pid_t pid, pid_t tid,
                         enum managed_class thread_class) {
    unsigned long long start_time = proc_start_time(tid);
    struct policy_task *record;
    if (start_time == 0) return -1;
    record = find_task(policy, tid, start_time);
    if (record == NULL) {
        if (policy->task_count >= POLICY_MAX_TASKS) return -1;
        record = &policy->tasks[policy->task_count++];
        memset(record, 0, sizeof(*record));
        record->pid = pid;
        record->tid = tid;
        record->start_time = start_time;
        record->original_mask = proc_get_affinity(tid);
        if (record->original_mask == 0 ||
            proc_get_clamp(tid, &record->original_clamp) != 0) {
            policy->task_count--;
            return -1;
        }
    }
    configure_target(policy, record, thread_class);
    return 0;
}

static void collect_process(struct transition_policy *policy, pid_t pid,
                            int kind) {
    char directory_path[64];
    DIR *directory;
    struct dirent *entry;
    if (pid <= 1) return;
    snprintf(directory_path, sizeof(directory_path), "/proc/%d/task", pid);
    directory = opendir(directory_path);
    if (directory == NULL) return;
    while ((entry = readdir(directory)) != NULL) {
        char *end;
        long parsed;
        char name[64];
        enum managed_class thread_class = MANAGED_NONE;
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9') continue;
        parsed = strtol(entry->d_name, &end, 10);
        if (*end != '\0' || parsed <= 1 || parsed > INT32_MAX ||
            proc_thread_name(pid, (pid_t)parsed, name, sizeof(name)) != 0)
            continue;
        if (kind == 1) thread_class = classify_launcher(name);
        else if (kind == 2) thread_class = classify_systemui(pid, (pid_t)parsed, name);
        else if (kind == 3) thread_class = classify_system_server(name);
        if (thread_class != MANAGED_NONE)
            (void)register_task(policy, pid, (pid_t)parsed, thread_class);
    }
    closedir(directory);
}

static int record_alive(const struct policy_task *record) {
    return proc_start_time(record->tid) == record->start_time;
}

static void apply_record(struct transition_policy *policy,
                         struct policy_task *record,
                         int validate_identity) {
    int corrected = 0;
    if (validate_identity && !record_alive(record)) return;
    if (record->affinity_managed &&
        proc_get_affinity(record->tid) != record->target_mask &&
        proc_set_affinity(record->tid, record->target_mask) == 0) {
        policy->corrections++;
        policy->affinity_corrections++;
        corrected = 1;
    }
    if (record->clamp_managed) {
        struct task_clamp current;
        if (proc_get_clamp(record->tid, &current) == 0 &&
            (current.minimum != record->target_clamp.minimum ||
             current.maximum != record->target_clamp.maximum) &&
            proc_set_clamp(record->tid, record->target_clamp.minimum,
                           record->target_clamp.maximum) == 0) {
            policy->corrections++;
            policy->clamp_corrections++;
            corrected = 1;
        }
    }
    if (!corrected) return;
    if (record->managed_class >= LAUNCHER_UI &&
        record->managed_class <= LAUNCHER_FENCE)
        policy->launcher_corrections++;
    else if (record->managed_class >= SYSTEMUI_CRITICAL &&
             record->managed_class <= SYSTEMUI_MAINTENANCE)
        policy->systemui_corrections++;
    else if (record->managed_class >= SYSTEM_SERVER_CRITICAL)
        policy->system_server_corrections++;
}

static void restore_record(struct policy_task *record, int affinity,
                           int clamp) {
    if (!record_alive(record)) return;
    if (affinity && record->affinity_managed)
        (void)proc_set_affinity(record->tid, record->original_mask);
    if (clamp && record->clamp_managed)
        (void)proc_set_clamp(record->tid, record->original_clamp.minimum,
                             record->original_clamp.maximum);
}

static void compact_tasks(struct transition_policy *policy) {
    size_t output = 0;
    for (size_t i = 0; i < policy->task_count; ++i) {
        if (policy->tasks[i].transient || !record_alive(&policy->tasks[i]))
            continue;
        if (output != i) policy->tasks[output] = policy->tasks[i];
        output++;
    }
    policy->task_count = output;
}

static void apply_auxiliary(struct transition_policy *policy,
                            const char *process_name) {
    struct auxiliary_process *record;
    pid_t pid;
    if (policy->auxiliary_count >= POLICY_MAX_AUXILIARY) return;
    pid = proc_find_exact(process_name);
    if (pid <= 1) return;
    record = &policy->auxiliary[policy->auxiliary_count];
    memset(record, 0, sizeof(*record));
    record->pid = pid;
    record->start_time = proc_start_time(pid);
    if (record->start_time == 0 ||
        proc_read_controller(pid, "cpuset", record->cpuset,
                             sizeof(record->cpuset)) != 0 ||
        proc_read_controller(pid, "cpu", record->cpuctl,
                             sizeof(record->cpuctl)) != 0)
        return;
    if (proc_move_controller(pid, "/dev/cpuset", "/background") == 0 &&
        proc_move_controller(pid, "/dev/cpuctl", "/background") == 0)
        policy->auxiliary_count++;
}

static long read_long(const char *path) {
    char text[64];
    char *end;
    long value;
    if (proc_read_text(path, text, sizeof(text)) != 0) return -1;
    value = strtol(text, &end, 10);
    return end == text ? -1 : value;
}

static int write_long(const char *path, long value) {
    char text[64];
    int fd;
    int length = snprintf(text, sizeof(text), "%ld\n", value);
    fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    if (write(fd, text, (size_t)length) != length) {
        close(fd);
        return -1;
    }
    close(fd);
    return 0;
}

static uint64_t cpulist_mask(const char *list) {
    char copy[256];
    char *token;
    char *save = NULL;
    uint64_t mask = 0;
    snprintf(copy, sizeof(copy), "%s", list);
    token = strtok_r(copy, ", ", &save);
    while (token != NULL) {
        char *dash = strchr(token, '-');
        long first = strtol(token, NULL, 10);
        long last = dash == NULL ? first : strtol(dash + 1, NULL, 10);
        for (long cpu = first; cpu <= last && cpu < 64; ++cpu)
            if (cpu >= 0) mask |= UINT64_C(1) << cpu;
        token = strtok_r(NULL, ", ", &save);
    }
    return mask;
}

static void apply_frequency_limit(struct transition_policy *policy) {
    DIR *directory = opendir("/sys/devices/system/cpu/cpufreq");
    struct dirent *entry;
    uint64_t little_mask = policy->config.masks[4];
    if (directory == NULL || policy->config.frequency_percent >= 100) return;
    while ((entry = readdir(directory)) != NULL &&
           policy->frequency_count < POLICY_MAX_FREQUENCIES) {
        char related_path[512];
        char maximum_path[512];
        char related[256];
        uint64_t mask;
        long original;
        long target;
        struct frequency_record *record;
        if (strncmp(entry->d_name, "policy", 6) != 0) continue;
        snprintf(related_path, sizeof(related_path),
                 "/sys/devices/system/cpu/cpufreq/%s/related_cpus", entry->d_name);
        if (proc_read_text(related_path, related, sizeof(related)) != 0) continue;
        mask = cpulist_mask(related);
        if (mask == 0 || (mask & ~little_mask) != 0) continue;
        snprintf(maximum_path, sizeof(maximum_path),
                 "/sys/devices/system/cpu/cpufreq/%s/scaling_max_freq",
                 entry->d_name);
        original = read_long(maximum_path);
        if (original <= 0) continue;
        target = original * (long)policy->config.frequency_percent / 100;
        if (target >= original || write_long(maximum_path, target) != 0) continue;
        record = &policy->frequencies[policy->frequency_count++];
        snprintf(record->path, sizeof(record->path), "%s", maximum_path);
        record->original = original;
        record->applied = read_long(maximum_path);
    }
    closedir(directory);
}

int transition_policy_initialize(struct transition_policy *policy,
                                 const struct transition_policy_config *config) {
    memset(policy, 0, sizeof(*policy));
    policy->config = *config;
    if (config->launcher_enabled) {
        pid_t launcher = proc_find_exact("com.miui.home");
        collect_process(policy, launcher, 1);
        for (size_t i = 0; i < policy->task_count; ++i) {
            struct policy_task *record = &policy->tasks[i];
            if (record->affinity_managed && record_alive(record))
                (void)proc_set_affinity(record->tid, record->target_mask);
        }
    }
    return 0;
}

int transition_policy_begin(struct transition_policy *policy) {
    pid_t launcher;
    int was_active = policy->active;
    if (!was_active) compact_tasks(policy);
    if (policy->config.launcher_enabled) {
        launcher = proc_find_exact("com.miui.home");
        collect_process(policy, launcher, 1);
    }
    if (policy->config.systemui_enabled)
        collect_process(policy, proc_find_exact("com.android.systemui"), 2);
    if (policy->config.system_server_enabled)
        collect_process(policy, proc_find_exact("system_server"), 3);
    if (!was_active) {
        for (size_t i = 0; i < policy->task_count; ++i) {
            struct policy_task *record = &policy->tasks[i];
            if (!record->transient && record->clamp_managed &&
                record_alive(record))
                (void)proc_get_clamp(record->tid, &record->original_clamp);
        }
    }
    policy->active = 1;
    for (size_t i = 0; i < policy->task_count; ++i)
        apply_record(policy, &policy->tasks[i], 1);
    if (!was_active && policy->config.auxiliary_enabled) {
        apply_auxiliary(policy, "com.miui.miwallpaper");
        apply_auxiliary(policy, "vendor.xiaomi.hardware.mimd@2.0-service");
    }
    if (!was_active && policy->config.frequency_enabled) apply_frequency_limit(policy);
    return 0;
}

void transition_policy_reassert(struct transition_policy *policy) {
    if (!policy->active) return;
    for (size_t i = 0; i < policy->task_count; ++i)
        apply_record(policy, &policy->tasks[i], 0);
}

void transition_policy_complete(struct transition_policy *policy) {
    if (!policy->active) return;
    for (size_t i = 0; i < policy->task_count; ++i) {
        if (policy->tasks[i].transient)
            restore_record(&policy->tasks[i], 1, 1);
        else
            restore_record(&policy->tasks[i], 0, 1);
    }
    for (size_t i = 0; i < policy->auxiliary_count; ++i) {
        struct auxiliary_process *record = &policy->auxiliary[i];
        if (proc_start_time(record->pid) != record->start_time) continue;
        (void)proc_move_controller(record->pid, "/dev/cpuset", record->cpuset);
        (void)proc_move_controller(record->pid, "/dev/cpuctl", record->cpuctl);
    }
    for (size_t i = 0; i < policy->frequency_count; ++i) {
        struct frequency_record *record = &policy->frequencies[i];
        if (read_long(record->path) == record->applied)
            (void)write_long(record->path, record->original);
    }
    policy->auxiliary_count = 0;
    policy->frequency_count = 0;
    policy->active = 0;
    compact_tasks(policy);
}

void transition_policy_destroy(struct transition_policy *policy) {
    transition_policy_complete(policy);
    for (size_t i = 0; i < policy->task_count; ++i)
        restore_record(&policy->tasks[i], 1, 1);
    policy->task_count = 0;
}
