#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define LOG_ID_MAIN 0
#define ANDROID_LOG_RDONLY 1
#define LOG_BUFFER_SIZE 65536
#define SOURCE_APP_FILE "/data/adb/modules/hyperos4_recents_source_app_yield/source-app"
#define SOURCE_AFFINITYCTL "/data/adb/modules/hyperos4_recents_source_app_yield/bin/source-affinityctl"
#define SOURCE_AFFINITY_STATE "/data/adb/modules/hyperos4_recents_source_app_yield/source-affinity.state"

static int cpuset_background_fd = -1;
static int cpuctl_background_fd = -1;

struct yield_result {
    int pid;
    int uid;
    int cpuset_ok;
    int cpuctl_ok;
    int affinity_status;
    int64_t delivery_us;
    int64_t write_us;
    int64_t affinity_us;
    int64_t cgroup_complete_monotonic_ns;
    int64_t complete_monotonic_ns;
};

typedef void logger_list;
typedef void logger;
typedef logger_list *(*list_alloc_fn)(int mode, unsigned int tail, int pid);
typedef logger *(*logger_open_fn)(logger_list *list, int id);
typedef int (*list_read_fn)(logger_list *list, void *message);
typedef void (*list_free_fn)(logger_list *list);

struct logger_entry_v4 {
    uint16_t len;
    uint16_t hdr_size;
    int32_t pid;
    uint32_t tid;
    uint32_t sec;
    uint32_t nsec;
    uint32_t lid;
    uint32_t uid;
};

static int is_relevant(const char *message) {
    static const char *scene_needles[] = {
        "SceneAnimationSignalType.gestureStart",
        "SceneAnimationSignalType.gestureToHome",
        "SceneAnimationSignalType.gestureToApp",
        "SceneAnimationSignalType.enterOverviewState",
        "SceneAnimationSignalType.exitOverviewState",
        "SceneAnimationSignalType.openingRemoteAnimationOpen",
        "SceneAnimationSignalType.openingRemoteAnimationClose",
    };
    size_t i;
    if (strstr(message, "activityResumed pkg=") != NULL ||
        strstr(message, "onOverviewToggle is_home_and_overview_same=true") != NULL ||
        strstr(message, "IRecentsAnimationRunnerImplForRemoteBack on_animation_start called type: CloseApp") != NULL ||
        (strstr(message, "IRecentsAnimationRunnerImplForRemoteBack") != NULL &&
         strstr(message, "on_animation_canceled") != NULL)) {
        return 1;
    }
    if (strstr(message, "SceneTransitionDetectorService detectSceneTransition:") == NULL) {
        return 0;
    }
    for (i = 0; i < sizeof(scene_needles) / sizeof(scene_needles[0]); ++i) {
        if (strstr(message, scene_needles[i]) != NULL) return 1;
    }
    return 0;
}

static int is_launcher_entry_start(const char *message) {
    return strstr(message, "SceneAnimationSignalType.gestureStart") != NULL ||
           strstr(message, "onOverviewToggle is_home_and_overview_same=true") != NULL ||
           strstr(message, "IRecentsAnimationRunnerImplForRemoteBack on_animation_start called type: CloseApp") != NULL;
}

static int64_t timespec_diff_us(const struct timespec *end, const struct timespec *start) {
    return ((int64_t)end->tv_sec - (int64_t)start->tv_sec) * 1000000LL +
           ((int64_t)end->tv_nsec - (int64_t)start->tv_nsec) / 1000LL;
}

static int write_pid_file(const char *path, int pid) {
    char value[32];
    int fd;
    int length = snprintf(value, sizeof(value), "%d\n", pid);
    if (length <= 0 || (size_t)length >= sizeof(value)) return 0;
    fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    if (write(fd, value, (size_t)length) != length) {
        close(fd);
        return 0;
    }
    close(fd);
    return 1;
}

static int write_pid_open_fd(int fd, const char *fallback_path, int pid) {
    char value[32];
    int length = snprintf(value, sizeof(value), "%d\n", pid);
    if (length <= 0 || (size_t)length >= sizeof(value)) return 0;
    if (fd >= 0) {
        (void)lseek(fd, 0, SEEK_SET);
        if (write(fd, value, (size_t)length) == length) return 1;
    }
    return write_pid_file(fallback_path, pid);
}

static int read_source_record(int *pid, int *uid) {
    char value[128];
    char *end;
    char *uid_start;
    long parsed_pid;
    long parsed_uid;
    int fd = open(SOURCE_APP_FILE, O_RDONLY | O_CLOEXEC);
    ssize_t length;
    if (fd < 0) return -1;
    length = read(fd, value, sizeof(value) - 1);
    close(fd);
    if (length <= 0) return -1;
    value[length] = '\0';
    parsed_pid = strtol(value, &end, 10);
    if (end == value || parsed_pid <= 1 || parsed_pid > INT32_MAX) return -1;
    while (*end == ' ' || *end == '\t') end++;
    uid_start = end;
    parsed_uid = strtol(uid_start, &end, 10);
    if (end == uid_start || parsed_uid < 1000 || parsed_uid > INT32_MAX) return -1;
    *pid = (int)parsed_pid;
    *uid = (int)parsed_uid;
    return 0;
}

static int run_affinity_apply(int pid, int uid) {
    char pid_text[32];
    char uid_text[32];
    char *arguments[] = {
        (char *)SOURCE_AFFINITYCTL,
        (char *)"apply",
        pid_text,
        uid_text,
        (char *)SOURCE_AFFINITY_STATE,
        NULL,
    };
    posix_spawn_file_actions_t actions;
    pid_t child;
    int status;
    int null_fd;
    int spawn_result;
    extern char **environ;
    snprintf(pid_text, sizeof(pid_text), "%d", pid);
    snprintf(uid_text, sizeof(uid_text), "%d", uid);
    null_fd = open("/dev/null", O_WRONLY | O_CLOEXEC);
    if (null_fd < 0) return -1;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        close(null_fd);
        return -1;
    }
    posix_spawn_file_actions_adddup2(&actions, null_fd, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, null_fd, STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, null_fd);
    spawn_result = posix_spawn(&child, SOURCE_AFFINITYCTL, &actions,
                               NULL, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(null_fd);
    if (spawn_result != 0) return -1;
    do {
        if (waitpid(child, &status, 0) >= 0) break;
        if (errno != EINTR) return -1;
    } while (errno == EINTR);
    if (!WIFEXITED(status)) return -1;
    return WEXITSTATUS(status);
}

static struct yield_result yield_source_native(void) {
    struct yield_result result = {-1, -1, 0, 0, -1, -1, -1, -1, -1, -1};
    struct timespec start;
    struct timespec cgroup_end;
    struct timespec end;
    if (read_source_record(&result.pid, &result.uid) != 0) return result;
    clock_gettime(CLOCK_MONOTONIC, &start);
    result.cpuset_ok = write_pid_open_fd(cpuset_background_fd,
                                        "/dev/cpuset/background/cgroup.procs", result.pid);
    result.cpuctl_ok = write_pid_open_fd(cpuctl_background_fd,
                                        "/dev/cpuctl/background/cgroup.procs", result.pid);
    clock_gettime(CLOCK_MONOTONIC, &cgroup_end);
    result.write_us = timespec_diff_us(&cgroup_end, &start);
    result.cgroup_complete_monotonic_ns =
        (int64_t)cgroup_end.tv_sec * 1000000000LL + cgroup_end.tv_nsec;
    result.affinity_status = run_affinity_apply(result.pid, result.uid);
    clock_gettime(CLOCK_MONOTONIC, &end);
    result.affinity_us = timespec_diff_us(&end, &cgroup_end);
    result.complete_monotonic_ns = (int64_t)end.tv_sec * 1000000000LL + end.tv_nsec;
    return result;
}

static void move_watcher_to_foreground(void) {
    int pid = getpid();
    /* The reader blocks in logd while idle.  Foreground placement avoids
       background starvation without turning the log reader into top-app work. */
    write_pid_file("/dev/cpuset/foreground/cgroup.procs", pid);
    write_pid_file("/dev/cpuctl/foreground/cgroup.procs", pid);
}

static void write_all(const char *buffer, size_t length) {
    while (length > 0) {
        ssize_t written = write(STDOUT_FILENO, buffer, length);
        if (written <= 0) _exit(2);
        buffer += written;
        length -= (size_t)written;
    }
}

int main(void) {
    unsigned char raw[LOG_BUFFER_SIZE];
    char output[LOG_BUFFER_SIZE];
    void *library = dlopen("liblog.so", RTLD_NOW | RTLD_LOCAL);
    list_alloc_fn list_alloc;
    logger_open_fn logger_open;
    list_read_fn list_read;
    list_free_fn list_free;
    logger_list *list;

    if (library == NULL) return 10;
    /* The watcher sleeps inside logd while idle.  Foreground placement prevents
       an all-core workload from starving the one short transition-edge write. */
    move_watcher_to_foreground();
    cpuset_background_fd = open("/dev/cpuset/background/cgroup.procs", O_WRONLY | O_CLOEXEC);
    cpuctl_background_fd = open("/dev/cpuctl/background/cgroup.procs", O_WRONLY | O_CLOEXEC);
    list_alloc = (list_alloc_fn)dlsym(library, "android_logger_list_alloc");
    logger_open = (logger_open_fn)dlsym(library, "android_logger_open");
    list_read = (list_read_fn)dlsym(library, "android_logger_list_read");
    list_free = (list_free_fn)dlsym(library, "android_logger_list_free");
    if (list_alloc == NULL || logger_open == NULL || list_read == NULL || list_free == NULL) return 11;

    list = list_alloc(ANDROID_LOG_RDONLY, 1, 0);
    if (list == NULL || logger_open(list, LOG_ID_MAIN) == NULL) return 12;

    for (;;) {
        struct logger_entry_v4 *entry;
        unsigned char *payload;
        size_t payload_length;
        const char *tag;
        const char *message;
        size_t tag_length;
        size_t message_limit;
        size_t message_length;
        struct yield_result yield = {-1, -1, 0, 0, -1, -1, -1, -1, -1, -1};
        char suffix[320] = "";
        int count;
        int read_result = list_read(list, raw);
        if (read_result <= 0) break;
        if ((size_t)read_result < sizeof(struct logger_entry_v4)) continue;

        entry = (struct logger_entry_v4 *)raw;
        if (entry->hdr_size < 20 || entry->hdr_size >= (uint16_t)read_result) continue;
        if ((size_t)entry->hdr_size + entry->len > (size_t)read_result) continue;
        payload = raw + entry->hdr_size;
        payload_length = entry->len;
        if (payload_length < 3) continue;

        tag = (const char *)(payload + 1);
        tag_length = strnlen(tag, payload_length - 1);
        if (tag_length >= payload_length - 1) continue;
        message = tag + tag_length + 1;
        message_limit = payload_length - 1 - tag_length - 1;
        message_length = strnlen(message, message_limit);
        if (message_length >= message_limit || !is_relevant(message)) continue;

        if (is_launcher_entry_start(message)) {
            struct timespec observed;
            struct timespec emitted = {(time_t)entry->sec, (long)entry->nsec};
            yield = yield_source_native();
            clock_gettime(CLOCK_REALTIME, &observed);
            yield.delivery_us = timespec_diff_us(&observed, &emitted) -
                                yield.write_us - yield.affinity_us;
            if (yield.delivery_us < 0 || yield.delivery_us > 5000000) yield.delivery_us = -1;
            snprintf(suffix, sizeof(suffix),
                     " nativeYieldPid=%d nativeYieldUid=%d nativeAffinityStatus=%d nativeAffinityUs=%lld nativeYieldCpuset=%d nativeYieldCpuctl=%d nativeDeliveryUs=%lld nativeYieldUs=%lld nativeCgroupCompleteNs=%lld nativeCompleteNs=%lld",
                     yield.pid, yield.uid, yield.affinity_status,
                     (long long)yield.affinity_us, yield.cpuset_ok, yield.cpuctl_ok,
                     (long long)yield.delivery_us, (long long)yield.write_us,
                     (long long)yield.cgroup_complete_monotonic_ns,
                     (long long)yield.complete_monotonic_ns);
        }

        count = snprintf(output, sizeof(output), "%u.%09u|%d|%s|%s%s\n",
                         entry->sec, entry->nsec, entry->pid, tag, message, suffix);
        if (count > 0 && (size_t)count < sizeof(output)) write_all(output, (size_t)count);
    }

    list_free(list);
    if (cpuset_background_fd >= 0) close(cpuset_background_fd);
    if (cpuctl_background_fd >= 0) close(cpuctl_background_fd);
    dlclose(library);
    return 0;
}
