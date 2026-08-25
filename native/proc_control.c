#define _GNU_SOURCE

#include "proc_control.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef SCHED_FLAG_KEEP_POLICY
#define SCHED_FLAG_KEEP_POLICY 0x08
#endif
#ifndef SCHED_FLAG_KEEP_PARAMS
#define SCHED_FLAG_KEEP_PARAMS 0x10
#endif
#ifndef SCHED_FLAG_UTIL_CLAMP_MIN
#define SCHED_FLAG_UTIL_CLAMP_MIN 0x20
#endif
#ifndef SCHED_FLAG_UTIL_CLAMP_MAX
#define SCHED_FLAG_UTIL_CLAMP_MAX 0x40
#endif

struct sched_attr_local {
    uint32_t size;
    uint32_t policy;
    uint64_t flags;
    int32_t nice;
    uint32_t priority;
    uint64_t runtime;
    uint64_t deadline;
    uint64_t period;
    uint32_t util_min;
    uint32_t util_max;
};

int proc_read_text(const char *path, char *buffer, size_t size) {
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

unsigned long long proc_start_time(pid_t tid) {
    char path[64];
    char buffer[4096];
    char *cursor;
    char *token;
    char *save = NULL;
    int field = 3;
    snprintf(path, sizeof(path), "/proc/%d/stat", tid);
    if (proc_read_text(path, buffer, sizeof(buffer)) != 0) return 0;
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

static int read_cmdline(pid_t pid, char *buffer, size_t size) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);
    return proc_read_text(path, buffer, size);
}

pid_t proc_find_exact(const char *process_name) {
    DIR *directory = opendir("/proc");
    struct dirent *entry;
    pid_t selected = 0;
    if (directory == NULL || process_name == NULL) return 0;
    while ((entry = readdir(directory)) != NULL) {
        char *end;
        long parsed;
        char cmdline[256];
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9') continue;
        errno = 0;
        parsed = strtol(entry->d_name, &end, 10);
        if (errno != 0 || *end != '\0' || parsed <= 1 || parsed > INT32_MAX)
            continue;
        if (read_cmdline((pid_t)parsed, cmdline, sizeof(cmdline)) == 0 &&
            strcmp(cmdline, process_name) == 0 &&
            (selected == 0 || parsed < selected))
            selected = (pid_t)parsed;
    }
    closedir(directory);
    return selected;
}

int proc_thread_name(pid_t pid, pid_t tid, char *buffer, size_t size) {
    char path[96];
    size_t length;
    snprintf(path, sizeof(path), "/proc/%d/task/%d/comm", pid, tid);
    if (proc_read_text(path, buffer, size) != 0) return -1;
    length = strlen(buffer);
    while (length > 0 &&
           (buffer[length - 1] == '\n' || buffer[length - 1] == '\r'))
        buffer[--length] = '\0';
    return 0;
}

static void mask_to_set(uint64_t mask, cpu_set_t *set) {
    CPU_ZERO(set);
    for (unsigned cpu = 0; cpu < CPU_SETSIZE && cpu < 64; ++cpu)
        if ((mask & (UINT64_C(1) << cpu)) != 0) CPU_SET(cpu, set);
}

uint64_t proc_get_affinity(pid_t tid) {
    cpu_set_t set;
    uint64_t mask = 0;
    if (sched_getaffinity(tid, sizeof(set), &set) != 0) return 0;
    for (unsigned cpu = 0; cpu < CPU_SETSIZE && cpu < 64; ++cpu)
        if (CPU_ISSET(cpu, &set)) mask |= UINT64_C(1) << cpu;
    return mask;
}

int proc_set_affinity(pid_t tid, uint64_t mask) {
    cpu_set_t set;
    if (mask == 0) return -1;
    mask_to_set(mask, &set);
    return sched_setaffinity(tid, sizeof(set), &set);
}

int proc_get_clamp(pid_t tid, struct task_clamp *clamp) {
    struct sched_attr_local attr = {0};
    attr.size = sizeof(attr);
    if (syscall(__NR_sched_getattr, tid, &attr, sizeof(attr), 0) != 0) return -1;
    clamp->minimum = attr.util_min;
    clamp->maximum = attr.util_max;
    return 0;
}

int proc_set_clamp(pid_t tid, uint32_t minimum, uint32_t maximum) {
    struct sched_attr_local attr = {0};
    attr.size = sizeof(attr);
    if (syscall(__NR_sched_getattr, tid, &attr, sizeof(attr), 0) != 0) return -1;
    attr.size = sizeof(attr);
    attr.flags |= SCHED_FLAG_KEEP_POLICY | SCHED_FLAG_KEEP_PARAMS |
                  SCHED_FLAG_UTIL_CLAMP_MIN | SCHED_FLAG_UTIL_CLAMP_MAX;
    attr.util_min = minimum;
    attr.util_max = maximum;
    return (int)syscall(__NR_sched_setattr, tid, &attr, 0);
}

int proc_read_controller(pid_t pid, const char *controller, char *path,
                         size_t size) {
    char file[64];
    char text[4096];
    char *line;
    snprintf(file, sizeof(file), "/proc/%d/cgroup", pid);
    if (proc_read_text(file, text, sizeof(text)) != 0) return -1;
    line = strtok(text, "\n");
    while (line != NULL) {
        char *first = strchr(line, ':');
        char *second = first == NULL ? NULL : strchr(first + 1, ':');
        if (first != NULL && second != NULL) {
            *second = '\0';
            char controllers[256];
            snprintf(controllers, sizeof(controllers), ",%s,", first + 1);
            char needle[128];
            snprintf(needle, sizeof(needle), ",%s,", controller);
            if (strstr(controllers, needle) != NULL) {
                snprintf(path, size, "%s", second + 1);
                return 0;
            }
        }
        line = strtok(NULL, "\n");
    }
    return -1;
}

int proc_move_controller(pid_t pid, const char *root, const char *group) {
    char path[512];
    char value[32];
    int fd;
    int length;
    const char *relative = group;
    while (*relative == '/') relative++;
    if (*relative == '\0') snprintf(path, sizeof(path), "%s/cgroup.procs", root);
    else snprintf(path, sizeof(path), "%s/%s/cgroup.procs", root, relative);
    length = snprintf(value, sizeof(value), "%d\n", pid);
    fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    if (write(fd, value, (size_t)length) != length) {
        close(fd);
        return -1;
    }
    close(fd);
    return 0;
}
