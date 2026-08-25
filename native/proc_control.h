#ifndef HYPEROS4_PROC_CONTROL_H
#define HYPEROS4_PROC_CONTROL_H

#include <sched.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

struct task_clamp {
    uint32_t minimum;
    uint32_t maximum;
};

int proc_read_text(const char *path, char *buffer, size_t size);
unsigned long long proc_start_time(pid_t tid);
pid_t proc_find_exact(const char *process_name);
int proc_thread_name(pid_t pid, pid_t tid, char *buffer, size_t size);
uint64_t proc_get_affinity(pid_t tid);
int proc_set_affinity(pid_t tid, uint64_t mask);
int proc_get_clamp(pid_t tid, struct task_clamp *clamp);
int proc_set_clamp(pid_t tid, uint32_t minimum, uint32_t maximum);
int proc_read_controller(pid_t pid, const char *controller, char *path,
                         size_t size);
int proc_move_controller(pid_t pid, const char *root, const char *group);

#endif
