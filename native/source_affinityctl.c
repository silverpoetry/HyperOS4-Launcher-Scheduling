#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define MINOR_WINDOW_NODE "/sys/module/metis/parameters/minor_window_app"
#define BACKGROUND_CPU_FILE "/dev/cpuset/background/cpus"
#define TOP_APP_CPU_FILE "/dev/cpuset/top-app/cpus"
#define BACKGROUND_CPUSET_PROCS "/dev/cpuset/background/cgroup.procs"
#define BACKGROUND_CPUCTL_PROCS "/dev/cpuctl/background/cgroup.procs"
#define SOURCE_PLACEMENT_FILE "/data/adb/hyperos4-launcher-scheduling/source-placement"
#define THREAD_TOPOLOGY_FILE "/data/adb/modules/hyperos4_recents_source_app_yield/launcher-thread-topology"
#define MAX_TASKS 4096

struct task_record {
    pid_t tid;
    unsigned long long start_time;
    unsigned long long original_mask;
};

static long long monotonic_us(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long long)now.tv_sec * 1000000LL + now.tv_nsec / 1000LL;
}

static int read_text(const char *path, char *buffer, size_t size) {
    int fd;
    ssize_t length;
    if (size < 2) return -1;
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    length = read(fd, buffer, size - 1);
    close(fd);
    if (length <= 0) return -1;
    buffer[length] = '\0';
    return 0;
}

static int write_number(const char *path, long value) {
    char buffer[64];
    int fd;
    int length = snprintf(buffer, sizeof(buffer), "%ld\n", value);
    if (length <= 0 || (size_t)length >= sizeof(buffer)) return -1;
    fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    if (write(fd, buffer, (size_t)length) != length) {
        close(fd);
        return -1;
    }
    close(fd);
    return 0;
}

static int write_pid(const char *path, pid_t pid) {
    char buffer[64];
    int fd;
    int length = snprintf(buffer, sizeof(buffer), "%d\n", pid);
    if (length <= 0 || (size_t)length >= sizeof(buffer)) return -1;
    fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    if (write(fd, buffer, (size_t)length) != length) {
        close(fd);
        return -1;
    }
    close(fd);
    return 0;
}

static int lock_state(const char *path) {
    char lock_path[512];
    int fd;
    int length = snprintf(lock_path, sizeof(lock_path), "%s.lock", path);
    if (length <= 0 || (size_t)length >= sizeof(lock_path)) return -1;
    fd = open(lock_path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static long read_number(const char *path) {
    char buffer[64];
    char *end;
    long value;
    if (read_text(path, buffer, sizeof(buffer)) != 0) return -1;
    errno = 0;
    value = strtol(buffer, &end, 10);
    if (errno != 0 || end == buffer) return -1;
    return value;
}

static unsigned long long cpulist_mask(const char *text) {
    unsigned long long mask = 0;
    const char *cursor = text;
    while (*cursor != '\0') {
        char *end;
        long first;
        long last;
        while (*cursor == ' ' || *cursor == '\t' || *cursor == ',') cursor++;
        if (*cursor == '\0' || *cursor == '\n') break;
        errno = 0;
        first = strtol(cursor, &end, 10);
        if (errno != 0 || end == cursor || first < 0 || first >= 64) return 0;
        cursor = end;
        last = first;
        if (*cursor == '-') {
            cursor++;
            errno = 0;
            last = strtol(cursor, &end, 10);
            if (errno != 0 || end == cursor || last < first || last >= 64) return 0;
            cursor = end;
        }
        for (long cpu = first; cpu <= last; ++cpu) mask |= 1ULL << cpu;
        if (*cursor == ',') cursor++;
    }
    return mask;
}

static unsigned long long read_cpu_mask(const char *path) {
    char buffer[256];
    if (read_text(path, buffer, sizeof(buffer)) != 0) return 0;
    return cpulist_mask(buffer);
}

static unsigned long long read_background_mask(void) {
    return read_cpu_mask(BACKGROUND_CPU_FILE);
}

static unsigned long long read_source_target_mask(void) {
    char topology[512];
    unsigned long long all_mask;
    unsigned long long perf_mask;
    unsigned long long mid_mask;
    unsigned long long little_mask;
    unsigned long long render_mask;
    unsigned long long prime_mask;
    unsigned long long secondary_mask;
    unsigned long long background_mask;
    unsigned long long selected;
    unsigned long long cgroup_mask = read_background_mask();
    long placement = read_number(SOURCE_PLACEMENT_FILE);
    int parsed;

    if (read_text(THREAD_TOPOLOGY_FILE, topology, sizeof(topology)) != 0)
        return cgroup_mask;
    parsed = sscanf(topology, "%llx %llx %llx %llx %llx %llx %llx %llx",
                    &all_mask, &perf_mask, &mid_mask, &little_mask,
                    &render_mask, &prime_mask, &secondary_mask, &background_mask);
    if (parsed != 8) return cgroup_mask;
    selected = placement == 5 ? little_mask : background_mask;
    selected &= cgroup_mask;
    return selected != 0 ? selected : cgroup_mask;
}

static void mask_to_cpuset(unsigned long long mask, cpu_set_t *set) {
    CPU_ZERO(set);
    for (int cpu = 0; cpu < CPU_SETSIZE && cpu < 64; ++cpu) {
        if ((mask & (1ULL << cpu)) != 0) CPU_SET(cpu, set);
    }
}

static unsigned long long cpuset_to_mask(const cpu_set_t *set) {
    unsigned long long mask = 0;
    for (int cpu = 0; cpu < CPU_SETSIZE && cpu < 64; ++cpu) {
        if (CPU_ISSET(cpu, set)) mask |= 1ULL << cpu;
    }
    return mask;
}

static unsigned long long task_start_time(pid_t tid) {
    char path[64];
    char buffer[4096];
    char *cursor;
    char *end;
    int field = 3;
    snprintf(path, sizeof(path), "/proc/%d/stat", tid);
    if (read_text(path, buffer, sizeof(buffer)) != 0) return 0;
    cursor = strrchr(buffer, ')');
    if (cursor == NULL || cursor[1] != ' ') return 0;
    cursor += 2;
    while (field <= 22) {
        while (*cursor == ' ') cursor++;
        if (*cursor == '\0') return 0;
        errno = 0;
        unsigned long long value = strtoull(cursor, &end, 10);
        if (field == 3) {
            end = cursor;
            while (*end != '\0' && *end != ' ') end++;
        } else if (errno != 0 || end == cursor) {
            return 0;
        }
        if (field == 22) return value;
        cursor = end;
        field++;
    }
    return 0;
}

static int collect_tasks(pid_t pid, struct task_record *records, size_t *count) {
    char directory_path[64];
    DIR *directory;
    struct dirent *entry;
    size_t used = 0;
    snprintf(directory_path, sizeof(directory_path), "/proc/%d/task", pid);
    directory = opendir(directory_path);
    if (directory == NULL) return -1;
    while ((entry = readdir(directory)) != NULL) {
        char *end;
        long parsed;
        cpu_set_t affinity;
        unsigned long long start;
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9') continue;
        parsed = strtol(entry->d_name, &end, 10);
        if (*end != '\0' || parsed <= 1 || parsed > INT32_MAX) continue;
        if (used >= MAX_TASKS) {
            closedir(directory);
            return -1;
        }
        start = task_start_time((pid_t)parsed);
        if (start == 0) continue;
        if (sched_getaffinity((pid_t)parsed, sizeof(affinity), &affinity) != 0) continue;
        records[used].tid = (pid_t)parsed;
        records[used].start_time = start;
        records[used].original_mask = cpuset_to_mask(&affinity);
        used++;
    }
    closedir(directory);
    *count = used;
    return used > 0 ? 0 : -1;
}

static int save_state(const char *path, pid_t pid, uid_t uid, long minor,
                      unsigned long long target_mask,
                      const struct task_record *records, size_t count) {
    char temporary[512];
    FILE *file;
    int length = snprintf(temporary, sizeof(temporary), "%s.tmp", path);
    if (length <= 0 || (size_t)length >= sizeof(temporary)) return -1;
    file = fopen(temporary, "we");
    if (file == NULL) return -1;
    fprintf(file, "SAF1 %d %u %ld %llx %zu\n", pid, uid, minor, target_mask, count);
    for (size_t i = 0; i < count; ++i) {
        fprintf(file, "%d %llu %llx\n", records[i].tid,
                records[i].start_time, records[i].original_mask);
    }
    if (fflush(file) != 0 || fclose(file) != 0) {
        unlink(temporary);
        return -1;
    }
    if (rename(temporary, path) != 0) {
        unlink(temporary);
        return -1;
    }
    chmod(path, 0600);
    return 0;
}

static int restore_state(const char *path, int remove_state, int restore_minor) {
    FILE *file = fopen(path, "re");
    char magic[8];
    int pid;
    unsigned int uid;
    long original_minor;
    unsigned long long target_mask;
    size_t expected;
    size_t restored = 0;
    size_t skipped = 0;
    if (file == NULL) return 2;
    if (fscanf(file, "%7s %d %u %ld %llx %zu", magic, &pid, &uid,
               &original_minor, &target_mask, &expected) != 6 ||
        strcmp(magic, "SAF1") != 0) {
        fclose(file);
        return 3;
    }
    for (size_t i = 0; i < expected; ++i) {
        int tid;
        unsigned long long start;
        unsigned long long mask;
        cpu_set_t affinity;
        if (fscanf(file, "%d %llu %llx", &tid, &start, &mask) != 3) break;
        if (task_start_time((pid_t)tid) != start) {
            skipped++;
            continue;
        }
        mask_to_cpuset(mask, &affinity);
        if (sched_setaffinity((pid_t)tid, sizeof(affinity), &affinity) == 0) restored++;
        else skipped++;
    }
    fclose(file);
    if (restore_minor && original_minor >= 0 && read_number(MINOR_WINDOW_NODE) == 0)
        (void)write_number(MINOR_WINDOW_NODE, original_minor);
    if (remove_state) unlink(path);
    printf("restore pid=%d uid=%u restored=%zu skipped=%zu restore_minor=%d minor=%ld\n",
           pid, uid, restored, skipped, restore_minor,
           read_number(MINOR_WINDOW_NODE));
    return 0;
}

static int reassert_state(const char *path, FILE *file, pid_t pid, uid_t uid,
                          long original_minor, unsigned long long target_mask,
                          size_t expected) {
    struct task_record *saved = calloc(MAX_TASKS, sizeof(*saved));
    struct task_record *current = calloc(MAX_TASKS, sizeof(*current));
    size_t saved_count = 0;
    size_t current_count = 0;
    size_t added = 0;
    size_t applied = 0;
    size_t failed = 0;
    size_t escaped = 0;
    cpu_set_t target;
    long current_minor;
    unsigned long long restore_mask = read_cpu_mask(TOP_APP_CPU_FILE);
    long long started_us = monotonic_us();
    long long collected_us;
    long long saved_us;
    if (saved == NULL || current == NULL || expected > MAX_TASKS) {
        fclose(file);
        free(saved);
        free(current);
        return 4;
    }
    for (size_t i = 0; i < expected; ++i) {
        int tid;
        unsigned long long start;
        unsigned long long mask;
        if (fscanf(file, "%d %llu %llx", &tid, &start, &mask) != 3) break;
        saved[saved_count].tid = (pid_t)tid;
        saved[saved_count].start_time = start;
        saved[saved_count].original_mask = mask;
        saved_count++;
    }
    fclose(file);
    if (collect_tasks(pid, current, &current_count) != 0) {
        free(saved);
        free(current);
        return 5;
    }
    collected_us = monotonic_us();
    for (size_t i = 0; i < current_count; ++i) {
        int found = 0;
        for (size_t j = 0; j < saved_count; ++j) {
            if (saved[j].tid == current[i].tid &&
                saved[j].start_time == current[i].start_time) {
                found = 1;
                break;
            }
        }
        if (!found) {
            if (saved_count >= MAX_TASKS) {
                free(saved);
                free(current);
                return 5;
            }
            saved[saved_count++] = current[i];
            if ((saved[saved_count - 1].original_mask & ~target_mask) == 0 &&
                restore_mask != 0) {
                saved[saved_count - 1].original_mask = restore_mask;
            }
            added++;
        }
        if ((current[i].original_mask & ~target_mask) != 0) escaped++;
    }
    current_minor = read_number(MINOR_WINDOW_NODE);
    if (added == 0 && escaped == 0 && current_minor != (long)uid) {
        printf("active pid=%d uid=%u tasks=%zu target=%llx minor=%ld total_us=%lld\n",
               pid, uid, current_count, target_mask, current_minor,
               monotonic_us() - started_us);
        free(saved);
        free(current);
        return 0;
    }
    if (added > 0 &&
        save_state(path, pid, uid, original_minor, target_mask,
                   saved, saved_count) != 0) {
        free(saved);
        free(current);
        return 5;
    }
    saved_us = monotonic_us();
    if (current_minor == (long)uid && write_number(MINOR_WINDOW_NODE, 0) != 0) {
        free(saved);
        free(current);
        return 6;
    }
    mask_to_cpuset(target_mask, &target);
    for (size_t i = 0; i < current_count; ++i) {
        if ((current[i].original_mask & ~target_mask) == 0) continue;
        if (sched_setaffinity(current[i].tid, sizeof(target), &target) == 0) applied++;
        else if (errno != ESRCH) failed++;
    }
    printf("reassert pid=%d uid=%u tasks=%zu added=%zu escaped=%zu applied=%zu failed=%zu target=%llx minor_before=%ld minor_after=%ld collect_us=%lld save_us=%lld bind_us=%lld total_us=%lld\n",
           pid, uid, current_count, added, escaped, applied, failed, target_mask,
           current_minor, read_number(MINOR_WINDOW_NODE),
           collected_us - started_us, saved_us - collected_us,
           monotonic_us() - saved_us, monotonic_us() - started_us);
    free(saved);
    free(current);
    return failed == 0 ? 0 : 7;
}

static int apply_state(pid_t pid, uid_t uid, const char *path, int move_groups) {
    struct task_record *records = calloc(MAX_TASKS, sizeof(*records));
    size_t count = 0;
    size_t applied = 0;
    size_t failed = 0;
    unsigned long long target_mask = read_source_target_mask();
    cpu_set_t target;
    long original_minor = read_number(MINOR_WINDOW_NODE);
    FILE *existing = fopen(path, "re");
    long long started_us = monotonic_us();
    long long collected_us;
    long long saved_us;
    int cpuset_ok = 1;
    int cpuctl_ok = 1;
    if (existing != NULL) {
        char magic[8];
        int active_pid;
        unsigned int active_uid;
        long active_minor;
        unsigned long long active_mask;
        size_t active_count;
        int parsed = fscanf(existing, "%7s %d %u %ld %llx %zu", magic,
                            &active_pid, &active_uid, &active_minor,
                            &active_mask, &active_count);
        free(records);
        if (parsed == 6 && strcmp(magic, "SAF1") == 0 &&
            active_pid == pid && active_uid == uid) {
            if (move_groups) {
                cpuset_ok = write_pid(BACKGROUND_CPUSET_PROCS, pid) == 0;
                cpuctl_ok = write_pid(BACKGROUND_CPUCTL_PROCS, pid) == 0;
            }
            if (!cpuset_ok || !cpuctl_ok) {
                fclose(existing);
                return 10;
            }
            return reassert_state(path, existing, pid, uid, active_minor,
                                  active_mask, active_count);
        }
        fclose(existing);
        fprintf(stderr, "active affinity transaction belongs to another process\n");
        return 9;
    }
    if (records == NULL || target_mask == 0 || original_minor < 0) {
        free(records);
        return 4;
    }
    if (collect_tasks(pid, records, &count) != 0) {
        free(records);
        return 5;
    }
    collected_us = monotonic_us();
    if (save_state(path, pid, uid, original_minor, target_mask, records, count) != 0) {
        free(records);
        return 5;
    }
    saved_us = monotonic_us();
    if (original_minor == (long)uid && write_number(MINOR_WINDOW_NODE, 0) != 0) {
        unlink(path);
        free(records);
        return 6;
    }
    if (move_groups) {
        cpuset_ok = write_pid(BACKGROUND_CPUSET_PROCS, pid) == 0;
        cpuctl_ok = write_pid(BACKGROUND_CPUCTL_PROCS, pid) == 0;
    }
    mask_to_cpuset(target_mask, &target);
    for (size_t i = 0; i < count; ++i) {
        if (sched_setaffinity(records[i].tid, sizeof(target), &target) == 0) applied++;
        else if (errno != ESRCH) failed++;
    }
    printf("apply pid=%d uid=%u tasks=%zu applied=%zu failed=%zu target=%llx cpuset=%d cpuctl=%d minor_before=%ld minor_after=%ld collect_us=%lld save_us=%lld bind_us=%lld total_us=%lld\n",
           pid, uid, count, applied, failed, target_mask,
           cpuset_ok, cpuctl_ok, original_minor, read_number(MINOR_WINDOW_NODE),
           collected_us - started_us, saved_us - collected_us,
           monotonic_us() - saved_us, monotonic_us() - started_us);
    free(records);
    if (!cpuset_ok || !cpuctl_ok) return 10;
    return failed == 0 ? 0 : 7;
}

static int yield_state(pid_t pid, uid_t uid, const char *path) {
    /* apply_state snapshots top-app masks, moves both cgroups, and only then
       binds the saved TIDs. This ordering is one locked native transaction. */
    return apply_state(pid, uid, path, 1);
}

static int verify_state(pid_t pid) {
    struct task_record *records = calloc(MAX_TASKS, sizeof(*records));
    size_t count = 0;
    size_t constrained = 0;
    size_t escaped = 0;
    unsigned long long target = read_source_target_mask();
    if (records == NULL || target == 0 || collect_tasks(pid, records, &count) != 0) {
        free(records);
        return 4;
    }
    for (size_t i = 0; i < count; ++i) {
        if ((records[i].original_mask & ~target) == 0) constrained++;
        else escaped++;
    }
    printf("verify pid=%d tasks=%zu constrained=%zu escaped=%zu target=%llx minor=%ld\n",
           pid, count, constrained, escaped, target, read_number(MINOR_WINDOW_NODE));
    free(records);
    return escaped == 0 ? 0 : 8;
}

static int state_matches(const char *path, pid_t pid, uid_t uid) {
    FILE *file = fopen(path, "re");
    char magic[8];
    int active_pid;
    unsigned int active_uid;
    long minor;
    unsigned long long mask;
    size_t count;
    int parsed;
    if (file == NULL) return 0;
    parsed = fscanf(file, "%7s %d %u %ld %llx %zu", magic, &active_pid,
                    &active_uid, &minor, &mask, &count);
    fclose(file);
    return parsed == 6 && strcmp(magic, "SAF1") == 0 &&
           active_pid == pid && active_uid == uid;
}

int main(int argc, char **argv) {
    const char *state_path = NULL;
    int lock_fd;
    int result = 1;

    if (argc == 3 && strcmp(argv[1], "verify") == 0)
        return verify_state((pid_t)atoi(argv[2]));
    if (argc == 3 &&
        (strcmp(argv[1], "restore") == 0 ||
         strcmp(argv[1], "restore-no-minor") == 0)) {
        state_path = argv[2];
    } else if (argc == 5 &&
               (strcmp(argv[1], "apply") == 0 ||
                strcmp(argv[1], "replace") == 0 ||
                strcmp(argv[1], "replace-yield") == 0 ||
                strcmp(argv[1], "yield") == 0)) {
        state_path = argv[4];
    } else {
        fprintf(stderr, "usage: %s apply|replace|yield|replace-yield PID UID STATE | restore|restore-no-minor STATE | verify PID\n", argv[0]);
        return 1;
    }

    lock_fd = lock_state(state_path);
    if (lock_fd < 0) return 11;

    if (strcmp(argv[1], "restore") == 0) {
        result = restore_state(argv[2], 1, 1);
    } else if (strcmp(argv[1], "restore-no-minor") == 0) {
        result = restore_state(argv[2], 1, 0);
    } else if (strcmp(argv[1], "replace") == 0 ||
               strcmp(argv[1], "replace-yield") == 0) {
        pid_t pid = (pid_t)atoi(argv[2]);
        uid_t uid = (uid_t)strtoul(argv[3], NULL, 10);
        int move_groups = strcmp(argv[1], "replace-yield") == 0;
        if (state_matches(argv[4], pid, uid)) {
            result = apply_state(pid, uid, argv[4], move_groups);
        } else {
            if (access(argv[4], F_OK) == 0)
                result = restore_state(argv[4], 1, 0);
            else
                result = 0;
            if (result == 0) result = apply_state(pid, uid, argv[4], move_groups);
        }
    } else if (strcmp(argv[1], "yield") == 0) {
        result = yield_state((pid_t)atoi(argv[2]),
                             (uid_t)strtoul(argv[3], NULL, 10), argv[4]);
    } else if (strcmp(argv[1], "apply") == 0) {
        result = apply_state((pid_t)atoi(argv[2]),
                             (uid_t)strtoul(argv[3], NULL, 10), argv[4], 0);
    }

    close(lock_fd);
    return result;
}
