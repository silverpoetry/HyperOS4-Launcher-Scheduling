#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/types.h>
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
    uint32_t sched_policy;
    uint64_t sched_flags;
    int32_t sched_nice;
    uint32_t sched_priority;
    uint64_t sched_runtime;
    uint64_t sched_deadline;
    uint64_t sched_period;
    uint32_t sched_util_min;
    uint32_t sched_util_max;
};

struct counts {
    unsigned raster;
    unsigned ui;
    unsigned rust;
    unsigned resmgr;
    unsigned fence;
    unsigned affinity_fail;
    unsigned clamp_fail;
};

enum thread_class {
    CLASS_NONE,
    CLASS_RASTER,
    CLASS_UI,
    CLASS_RUST,
    CLASS_RESMGR,
    CLASS_FENCE,
};

static enum thread_class classify(const char *name) {
    if (strcmp(name, "1.raster") == 0) return CLASS_RASTER;
    if (strcmp(name, "1.ui") == 0) return CLASS_UI;
    if (strcmp(name, "rt-launcher-mai") == 0) return CLASS_RUST;
    if (strcmp(name, "IplrVkResMgr") == 0) return CLASS_RESMGR;
    if (strcmp(name, "IplrVkFenceWait") == 0) return CLASS_FENCE;
    return CLASS_NONE;
}

static int read_comm(pid_t pid, pid_t tid, char *buffer, size_t size) {
    char path[96];
    FILE *file;
    size_t length;
    snprintf(path, sizeof(path), "/proc/%d/task/%d/comm", pid, tid);
    file = fopen(path, "re");
    if (file == NULL) return -1;
    if (fgets(buffer, (int)size, file) == NULL) {
        fclose(file);
        return -1;
    }
    fclose(file);
    length = strlen(buffer);
    while (length > 0 && (buffer[length - 1] == '\n' || buffer[length - 1] == '\r')) {
        buffer[--length] = '\0';
    }
    return 0;
}

static int set_affinity_mask(pid_t tid, uint64_t mask) {
    cpu_set_t set;
    unsigned cpu;
    CPU_ZERO(&set);
    for (cpu = 0; cpu < CPU_SETSIZE && cpu < 64; ++cpu) {
        if ((mask & (UINT64_C(1) << cpu)) != 0) CPU_SET(cpu, &set);
    }
    return sched_setaffinity(tid, sizeof(set), &set);
}

static int set_uclamp(pid_t tid, uint32_t minimum, uint32_t maximum) {
    struct sched_attr_local attr;
    memset(&attr, 0, sizeof(attr));
    attr.size = sizeof(attr);
    if (syscall(__NR_sched_getattr, tid, &attr, sizeof(attr), 0) != 0) return -1;
    attr.size = sizeof(attr);
    attr.sched_flags |= SCHED_FLAG_KEEP_POLICY | SCHED_FLAG_KEEP_PARAMS |
                        SCHED_FLAG_UTIL_CLAMP_MIN | SCHED_FLAG_UTIL_CLAMP_MAX;
    attr.sched_util_min = minimum;
    attr.sched_util_max = maximum;
    return (int)syscall(__NR_sched_setattr, tid, &attr, 0);
}

static uint32_t boost_minimum(enum thread_class thread_class,
                              uint32_t raster_min, uint32_t ui_min,
                              uint32_t rust_min, uint32_t resmgr_min) {
    switch (thread_class) {
        case CLASS_RASTER: return raster_min;
        case CLASS_UI: return ui_min;
        case CLASS_RUST: return rust_min;
        case CLASS_RESMGR: return resmgr_min;
        default: return 0;
    }
}

static void increment_class(struct counts *counts, enum thread_class thread_class) {
    switch (thread_class) {
        case CLASS_RASTER: ++counts->raster; break;
        case CLASS_UI: ++counts->ui; break;
        case CLASS_RUST: ++counts->rust; break;
        case CLASS_RESMGR: ++counts->resmgr; break;
        case CLASS_FENCE: ++counts->fence; break;
        default: break;
    }
}

int main(int argc, char **argv) {
    char task_path[64];
    char comm[64];
    DIR *directory;
    struct dirent *entry;
    struct counts counts = {0};
    pid_t pid;
    uint64_t perf_mask = 0;
    uint64_t mid_mask = 0;
    uint64_t little_mask = 0;
    uint64_t prime_mask = 0;
    int reset_only;
    int placement_mode;
    int fence_placement;
    uint32_t raster_min = 0;
    uint32_t ui_min = 0;
    uint32_t rust_min = 0;
    uint32_t resmgr_min = 0;

    if (argc < 3) {
        fprintf(stderr,
                "usage: %s apply PID PERF MID LITTLE PRIME PLACEMENT FENCE_PLACEMENT RASTER_MIN UI_MIN RUST_MIN RESMGR_MIN | reset PID\n",
                argv[0]);
        return 2;
    }
    reset_only = strcmp(argv[1], "reset") == 0;
    if (!reset_only && strcmp(argv[1], "apply") != 0) return 2;
    pid = (pid_t)strtol(argv[2], NULL, 10);
    if (pid <= 0) return 2;
    placement_mode = 0;
    fence_placement = 1;
    if (!reset_only) {
        if (argc != 13) return 2;
        perf_mask = strtoull(argv[3], NULL, 16);
        mid_mask = strtoull(argv[4], NULL, 16);
        little_mask = strtoull(argv[5], NULL, 16);
        prime_mask = strtoull(argv[6], NULL, 16);
        placement_mode = atoi(argv[7]);
        fence_placement = atoi(argv[8]);
        raster_min = (uint32_t)strtoul(argv[9], NULL, 10);
        ui_min = (uint32_t)strtoul(argv[10], NULL, 10);
        rust_min = (uint32_t)strtoul(argv[11], NULL, 10);
        resmgr_min = (uint32_t)strtoul(argv[12], NULL, 10);
        if (placement_mode < 0 || placement_mode > 2) return 2;
        if (fence_placement < 1 || fence_placement > 2) return 2;
        if (raster_min > 1024 || ui_min > 1024 || rust_min > 1024 || resmgr_min > 1024) return 2;
        if (perf_mask == 0 || mid_mask == 0 || little_mask == 0 || prime_mask == 0) return 2;
    }

    snprintf(task_path, sizeof(task_path), "/proc/%d/task", pid);
    directory = opendir(task_path);
    if (directory == NULL) return 3;
    while ((entry = readdir(directory)) != NULL) {
        pid_t tid;
        enum thread_class thread_class;
        uint64_t affinity_mask;
        char *end;
        errno = 0;
        tid = (pid_t)strtol(entry->d_name, &end, 10);
        if (errno != 0 || *entry->d_name == '\0' || *end != '\0' || tid <= 0) continue;
        if (read_comm(pid, tid, comm, sizeof(comm)) != 0) continue;
        thread_class = classify(comm);
        if (thread_class == CLASS_NONE) continue;
        increment_class(&counts, thread_class);

        if (reset_only) {
            if (thread_class != CLASS_FENCE && set_uclamp(tid, 0, 1024) != 0) {
                ++counts.clamp_fail;
            }
            continue;
        }

        affinity_mask = perf_mask;
        if (thread_class == CLASS_RASTER) affinity_mask = prime_mask;
        if (placement_mode >= 2 && (thread_class == CLASS_UI || thread_class == CLASS_RUST)) affinity_mask = mid_mask;
        if (thread_class == CLASS_RESMGR) affinity_mask = mid_mask;
        if (thread_class == CLASS_FENCE) affinity_mask = fence_placement == 2 ? mid_mask : little_mask;
        if (set_affinity_mask(tid, affinity_mask) != 0) ++counts.affinity_fail;
        if (thread_class != CLASS_FENCE &&
            set_uclamp(tid, boost_minimum(thread_class, raster_min, ui_min,
                                         rust_min, resmgr_min), 1024) != 0) {
            ++counts.clamp_fail;
        }
    }
    closedir(directory);
    printf("raster=%u ui=%u rust=%u resmgr=%u fence=%u affinity_fail=%u clamp_fail=%u\n",
           counts.raster, counts.ui, counts.rust, counts.resmgr, counts.fence,
           counts.affinity_fail, counts.clamp_fail);
    return (counts.affinity_fail == 0 && counts.clamp_fail == 0) ? 0 : 4;
}
