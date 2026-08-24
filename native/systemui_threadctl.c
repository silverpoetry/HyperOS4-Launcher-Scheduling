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
#include <unistd.h>

#define MAX_RECORDS 512

enum thread_class {
    CLASS_NONE = 0,
    CLASS_CRITICAL = 1,
    CLASS_MAINTENANCE = 2,
};

struct record {
    pid_t tid;
    unsigned long long start_time;
    unsigned long long original_mask;
    int thread_class;
};

static int read_text(const char *path, char *buffer, size_t size) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    ssize_t length;
    if (fd < 0 || size < 2) return -1;
    length = read(fd, buffer, size - 1);
    close(fd);
    if (length <= 0) return -1;
    buffer[length] = '\0';
    return 0;
}

static unsigned long long task_start_time(pid_t tid) {
    char path[64];
    char buffer[4096];
    char *cursor;
    char *token;
    char *save;
    int field = 3;
    snprintf(path, sizeof(path), "/proc/%d/stat", tid);
    if (read_text(path, buffer, sizeof(buffer)) != 0) return 0;
    cursor = strrchr(buffer, ')');
    if (cursor == NULL || cursor[1] != ' ') return 0;
    cursor += 2;
    token = strtok_r(cursor, " ", &save);
    while (token != NULL) {
        if (field == 22) return strtoull(token, NULL, 10);
        field++;
        token = strtok_r(NULL, " ", &save);
    }
    return 0;
}

static int read_comm(pid_t pid, pid_t tid, char *buffer, size_t size) {
    char path[96];
    size_t length;
    snprintf(path, sizeof(path), "/proc/%d/task/%d/comm", pid, tid);
    if (read_text(path, buffer, size) != 0) return -1;
    length = strlen(buffer);
    while (length > 0 && (buffer[length - 1] == '\n' || buffer[length - 1] == '\r'))
        buffer[--length] = '\0';
    return 0;
}

static enum thread_class classify(pid_t pid, pid_t tid, const char *name) {
    if (tid == pid || strcmp(name, "RenderThread") == 0 ||
        strcmp(name, "wmshell.main") == 0 ||
        strcmp(name, "GPU completion") == 0 ||
        strcmp(name, "RE Completion") == 0)
        return CLASS_CRITICAL;
    if (strcmp(name, "HeapTaskDaemon") == 0 ||
        strcmp(name, "FinalizerDaemon") == 0 ||
        strncmp(name, "FinalizerWatchd", 15) == 0 ||
        strncmp(name, "ReferenceQueueD", 15) == 0 ||
        strcmp(name, "Jit thread pool") == 0 ||
        strcmp(name, "Profile Saver") == 0)
        return CLASS_MAINTENANCE;
    return CLASS_NONE;
}

static unsigned long long cpuset_to_mask(const cpu_set_t *set) {
    unsigned long long mask = 0;
    for (int cpu = 0; cpu < CPU_SETSIZE && cpu < 64; ++cpu)
        if (CPU_ISSET(cpu, set)) mask |= 1ULL << cpu;
    return mask;
}

static void mask_to_cpuset(unsigned long long mask, cpu_set_t *set) {
    CPU_ZERO(set);
    for (int cpu = 0; cpu < CPU_SETSIZE && cpu < 64; ++cpu)
        if ((mask & (1ULL << cpu)) != 0) CPU_SET(cpu, set);
}

static int collect(pid_t pid, struct record *records, size_t *count) {
    char path[64];
    char comm[64];
    DIR *directory;
    struct dirent *entry;
    size_t used = 0;
    snprintf(path, sizeof(path), "/proc/%d/task", pid);
    directory = opendir(path);
    if (directory == NULL) return -1;
    while ((entry = readdir(directory)) != NULL) {
        char *end;
        long parsed;
        enum thread_class thread_class;
        cpu_set_t affinity;
        unsigned long long start;
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9') continue;
        parsed = strtol(entry->d_name, &end, 10);
        if (*end != '\0' || parsed <= 1 || used >= MAX_RECORDS) continue;
        if (read_comm(pid, (pid_t)parsed, comm, sizeof(comm)) != 0) continue;
        thread_class = classify(pid, (pid_t)parsed, comm);
        if (thread_class == CLASS_NONE) continue;
        start = task_start_time((pid_t)parsed);
        if (start == 0 || sched_getaffinity((pid_t)parsed, sizeof(affinity), &affinity) != 0)
            continue;
        records[used].tid = (pid_t)parsed;
        records[used].start_time = start;
        records[used].original_mask = cpuset_to_mask(&affinity);
        records[used].thread_class = thread_class;
        used++;
    }
    closedir(directory);
    *count = used;
    return used > 0 ? 0 : -1;
}

static int lock_state(const char *path) {
    char lock_path[512];
    int fd;
    if (snprintf(lock_path, sizeof(lock_path), "%s.lock", path) >= (int)sizeof(lock_path))
        return -1;
    fd = open(lock_path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0 || flock(fd, LOCK_EX) != 0) {
        if (fd >= 0) close(fd);
        return -1;
    }
    return fd;
}

static int load_state(const char *path, pid_t *pid, unsigned long long *process_start,
                      struct record *records, size_t *count) {
    FILE *file = fopen(path, "re");
    char magic[8];
    size_t expected;
    size_t used = 0;
    if (file == NULL) return 1;
    if (fscanf(file, "%7s %d %llu %zu", magic, pid, process_start, &expected) != 4 ||
        strcmp(magic, "SUI1") != 0 || expected > MAX_RECORDS) {
        fclose(file);
        return 2;
    }
    while (used < expected &&
           fscanf(file, "%d %llu %llx %d", &records[used].tid,
                  &records[used].start_time, &records[used].original_mask,
                  &records[used].thread_class) == 4)
        used++;
    fclose(file);
    *count = used;
    return used == expected ? 0 : 2;
}

static int save_state(const char *path, pid_t pid, unsigned long long process_start,
                      const struct record *records, size_t count) {
    char temporary[512];
    FILE *file;
    if (snprintf(temporary, sizeof(temporary), "%s.tmp", path) >= (int)sizeof(temporary))
        return -1;
    file = fopen(temporary, "we");
    if (file == NULL) return -1;
    fprintf(file, "SUI1 %d %llu %zu\n", pid, process_start, count);
    for (size_t i = 0; i < count; ++i)
        fprintf(file, "%d %llu %llx %d\n", records[i].tid,
                records[i].start_time, records[i].original_mask,
                records[i].thread_class);
    if (fflush(file) != 0 || fclose(file) != 0 || rename(temporary, path) != 0) {
        unlink(temporary);
        return -1;
    }
    chmod(path, 0600);
    return 0;
}

static unsigned long long select_mask(int placement,
                                      const unsigned long long masks[6]) {
    if (placement < 1 || placement > 6) return 0;
    return masks[placement - 1];
}

static int apply_policy(pid_t pid, const char *path,
                        const unsigned long long masks[6],
                        int critical_placement, int maintenance_placement) {
    struct record saved[MAX_RECORDS];
    struct record current[MAX_RECORDS];
    pid_t saved_pid = 0;
    unsigned long long saved_start = 0;
    unsigned long long process_start = task_start_time(pid);
    size_t saved_count = 0;
    size_t current_count = 0;
    size_t added = 0;
    size_t critical = 0;
    size_t maintenance = 0;
    size_t failed = 0;
    int state_result = load_state(path, &saved_pid, &saved_start, saved, &saved_count);
    if (process_start == 0 || collect(pid, current, &current_count) != 0) return 3;
    if (state_result != 0 || saved_pid != pid || saved_start != process_start) {
        saved_count = 0;
        unlink(path);
    }
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
            if (saved_count >= MAX_RECORDS) return 4;
            saved[saved_count++] = current[i];
            added++;
        }
    }
    if (added > 0 || state_result != 0) {
        if (save_state(path, pid, process_start, saved, saved_count) != 0) return 5;
    }
    for (size_t i = 0; i < current_count; ++i) {
        int placement = current[i].thread_class == CLASS_CRITICAL
                            ? critical_placement : maintenance_placement;
        unsigned long long mask = select_mask(placement, masks);
        cpu_set_t affinity;
        if (current[i].thread_class == CLASS_CRITICAL) critical++;
        else maintenance++;
        mask_to_cpuset(mask, &affinity);
        if (sched_setaffinity(current[i].tid, sizeof(affinity), &affinity) != 0 &&
            errno != ESRCH)
            failed++;
    }
    printf("apply pid=%d critical=%zu maintenance=%zu added=%zu failed=%zu\n",
           pid, critical, maintenance, added, failed);
    return failed == 0 ? 0 : 6;
}

static int restore_policy(const char *path) {
    struct record saved[MAX_RECORDS];
    pid_t pid = 0;
    unsigned long long process_start = 0;
    size_t count = 0;
    size_t restored = 0;
    size_t skipped = 0;
    int result = load_state(path, &pid, &process_start, saved, &count);
    if (result != 0) {
        unlink(path);
        return result == 1 ? 0 : 2;
    }
    for (size_t i = 0; i < count; ++i) {
        cpu_set_t affinity;
        if (task_start_time(saved[i].tid) != saved[i].start_time) {
            skipped++;
            continue;
        }
        mask_to_cpuset(saved[i].original_mask, &affinity);
        if (sched_setaffinity(saved[i].tid, sizeof(affinity), &affinity) == 0)
            restored++;
        else
            skipped++;
    }
    unlink(path);
    printf("restore pid=%d restored=%zu skipped=%zu\n", pid, restored, skipped);
    return 0;
}

int main(int argc, char **argv) {
    const char *state_path;
    int lock_fd;
    int result;
    if (argc == 3 && strcmp(argv[1], "restore") == 0) {
        state_path = argv[2];
        lock_fd = lock_state(state_path);
        if (lock_fd < 0) return 8;
        result = restore_policy(state_path);
        close(lock_fd);
        return result;
    }
    if (argc != 12 || strcmp(argv[1], "apply") != 0) {
        fprintf(stderr, "usage: %s apply PID STATE PERF MID LITTLE RENDER PRIME SECONDARY CRITICAL_PLACE MAINTENANCE_PLACE | restore STATE\n", argv[0]);
        return 2;
    }
    state_path = argv[3];
    unsigned long long masks[6] = {
        strtoull(argv[4], NULL, 16), strtoull(argv[5], NULL, 16),
        strtoull(argv[6], NULL, 16), strtoull(argv[7], NULL, 16),
        strtoull(argv[8], NULL, 16), strtoull(argv[9], NULL, 16),
    };
    int critical_placement = atoi(argv[10]);
    int maintenance_placement = atoi(argv[11]);
    for (int i = 0; i < 6; ++i) if (masks[i] == 0) return 2;
    if (critical_placement < 1 || critical_placement > 6 ||
        maintenance_placement < 1 || maintenance_placement > 6)
        return 2;
    lock_fd = lock_state(state_path);
    if (lock_fd < 0) return 8;
    result = apply_policy((pid_t)atoi(argv[2]), state_path, masks,
                          critical_placement, maintenance_placement);
    close(lock_fd);
    return result;
}
