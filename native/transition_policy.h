#ifndef HYPEROS4_TRANSITION_POLICY_H
#define HYPEROS4_TRANSITION_POLICY_H

#include <pthread.h>
#include <stdint.h>
#include <sys/types.h>

#include "proc_control.h"

#define POLICY_MASK_COUNT 8
#define POLICY_MAX_TASKS 1024
#define POLICY_MAX_AUXILIARY 4
#define POLICY_MAX_FREQUENCIES 16

struct transition_policy_config {
    int launcher_enabled;
    int systemui_enabled;
    int system_server_enabled;
    int auxiliary_enabled;
    int frequency_enabled;
    uint64_t masks[POLICY_MASK_COUNT];
    int launcher_placement;
    int raster_placement;
    int resmgr_placement;
    int fence_placement;
    int systemui_critical_placement;
    int systemui_maintenance_placement;
    int system_server_critical_placement;
    int system_server_snapshot_placement;
    uint32_t raster_min;
    uint32_t ui_min;
    uint32_t rust_min;
    uint32_t resmgr_min;
    unsigned frequency_percent;
};

struct policy_task {
    pid_t pid;
    pid_t tid;
    unsigned long long start_time;
    uint64_t original_mask;
    uint64_t target_mask;
    struct task_clamp original_clamp;
    struct task_clamp target_clamp;
    int affinity_managed;
    int clamp_managed;
    int transient;
    int managed_class;
};

struct auxiliary_process {
    pid_t pid;
    unsigned long long start_time;
    char cpuset[256];
    char cpuctl[256];
};

struct frequency_record {
    char path[256];
    long original;
    long applied;
};

struct transition_policy {
    struct transition_policy_config config;
    struct policy_task tasks[POLICY_MAX_TASKS];
    size_t task_count;
    struct auxiliary_process auxiliary[POLICY_MAX_AUXILIARY];
    size_t auxiliary_count;
    struct frequency_record frequencies[POLICY_MAX_FREQUENCIES];
    size_t frequency_count;
    int active;
    unsigned long corrections;
    unsigned long affinity_corrections;
    unsigned long clamp_corrections;
    unsigned long launcher_corrections;
    unsigned long systemui_corrections;
    unsigned long system_server_corrections;
};

int transition_policy_initialize(struct transition_policy *policy,
                                 const struct transition_policy_config *config);
int transition_policy_begin(struct transition_policy *policy);
void transition_policy_reassert(struct transition_policy *policy);
void transition_policy_complete(struct transition_policy *policy);
void transition_policy_destroy(struct transition_policy *policy);

#endif
