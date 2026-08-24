#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define LOG_ID_MAIN 0
#define LOG_ID_SYSTEM 3
#define ANDROID_LOG_RDONLY 1
#define LOG_BUFFER_SIZE 65536
#define SOURCE_APP_FILE "/data/adb/modules/hyperos4_recents_source_app_yield/source-app"
#define SOURCE_APP_NATIVE_TMP "/data/adb/modules/hyperos4_recents_source_app_yield/source-app.native.tmp"
#define SOURCE_GUARD_SOCKET "/dev/.hyperos4-launcher-scheduling/source-guard.sock"
#define SOURCE_GUARD_STATUS "/dev/.hyperos4-launcher-scheduling/source-guard.status"
#define SOURCE_CPUSET_PROCS "/dev/cpuset/hyperos4-source/cgroup.procs"
#define SOURCE_CPUCTL_PROCS "/dev/cpuctl/hyperos4-source/cgroup.procs"
#define PACKAGE_LENGTH 256

struct yield_result {
    int pid;
    int uid;
    int cpuset_ok;
    int cpuctl_ok;
    int guard_status;
    int64_t delivery_us;
    int64_t write_us;
    int64_t guard_us;
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
        strstr(message, "finish_remote_transition to_home = false") != NULL ||
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

static int read_source_record(int *pid, int *uid, char *package, size_t package_size) {
    char value[512];
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
    while (*end == ' ' || *end == '\t') end++;
    if (*end == '\0' || *end == '\n') return -1;
    {
        size_t length = strcspn(end, " \t\r\n");
        if (length == 0 || length >= package_size) return -1;
        memcpy(package, end, length);
        package[length] = '\0';
    }
    *pid = (int)parsed_pid;
    *uid = (int)parsed_uid;
    return 0;
}

static int guard_active(void) {
    char text[512];
    int fd = open(SOURCE_GUARD_STATUS, O_RDONLY | O_CLOEXEC);
    ssize_t length;
    if (fd < 0) return 0;
    length = read(fd, text, sizeof(text) - 1);
    close(fd);
    if (length <= 0) return 0;
    text[length] = '\0';
    return strstr(text, "active=1\n") != NULL;
}

static int send_guard_command(const char *operation, int pid, int uid) {
    struct sockaddr_un address;
    char command[96];
    int fd;
    int length = snprintf(command, sizeof(command), "%s %d %d", operation, pid, uid);
    if (length <= 0 || (size_t)length >= sizeof(command)) return -1;
    fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", SOURCE_GUARD_SOCKET);
    if (sendto(fd, command, (size_t)length + 1, 0,
               (struct sockaddr *)&address, sizeof(address)) < 0) {
        close(fd);
        return -1;
    }
    close(fd);
    return 0;
}

static struct yield_result yield_source_native(void) {
    struct yield_result result = {-1, -1, 0, 0, -1, -1, -1, -1, -1, -1};
    struct timespec start;
    struct timespec end;
    char package[PACKAGE_LENGTH];
    if (read_source_record(&result.pid, &result.uid, package, sizeof(package)) != 0) return result;
    clock_gettime(CLOCK_MONOTONIC, &start);
    result.cpuset_ok = write_pid_file(SOURCE_CPUSET_PROCS, result.pid);
    result.cpuctl_ok = write_pid_file(SOURCE_CPUCTL_PROCS, result.pid);
    result.guard_status = send_guard_command("activate", result.pid, result.uid);
    clock_gettime(CLOCK_MONOTONIC, &end);
    result.guard_us = timespec_diff_us(&end, &start);
    result.write_us = 0;
    if (!result.cpuset_ok || !result.cpuctl_ok) result.guard_status = -1;
    result.cgroup_complete_monotonic_ns =
        (int64_t)end.tv_sec * 1000000000LL + end.tv_nsec;
    result.complete_monotonic_ns = (int64_t)end.tv_sec * 1000000000LL + end.tv_nsec;
    return result;
}

static int parse_started_process(const char *message, int *pid, int *uid,
                                 char *process, size_t process_size) {
    const char *cursor;
    char *end;
    long parsed_pid;
    long user_id;
    long app_index;
    long parsed_uid;
    size_t length;
    cursor = strstr(message, "Start proc ");
    if (cursor == NULL) return -1;
    cursor += strlen("Start proc ");
    errno = 0;
    parsed_pid = strtol(cursor, &end, 10);
    if (errno != 0 || end == cursor || parsed_pid <= 1 ||
        parsed_pid > INT32_MAX || *end != ':') return -1;
    cursor = end + 1;
    length = strcspn(cursor, "/ \t\r\n");
    if (length == 0 || length >= process_size) return -1;
    memcpy(process, cursor, length);
    process[length] = '\0';
    cursor += length;
    if (cursor[0] != '/' || cursor[1] != 'u') return -1;
    cursor += 2;
    user_id = strtol(cursor, &end, 10);
    if (end == cursor || user_id < 0 || user_id > 99 || *end != 'a') return -1;
    cursor = end + 1;
    app_index = strtol(cursor, &end, 10);
    if (end == cursor || app_index < 0 || app_index > 89999) return -1;
    parsed_uid = user_id * 100000L + 10000L + app_index;
    if (parsed_uid > INT32_MAX) return -1;
    *pid = (int)parsed_pid;
    *uid = (int)parsed_uid;
    return 0;
}

static int write_source_record(int pid, int uid, const char *package) {
    char value[640];
    int fd;
    int length = snprintf(value, sizeof(value), "%d %d %s\n", pid, uid, package);
    if (length <= 0 || (size_t)length >= sizeof(value)) return -1;
    fd = open(SOURCE_APP_NATIVE_TMP,
              O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (write(fd, value, (size_t)length) != length) {
        close(fd);
        unlink(SOURCE_APP_NATIVE_TMP);
        return -1;
    }
    if (close(fd) != 0 || rename(SOURCE_APP_NATIVE_TMP, SOURCE_APP_FILE) != 0) {
        unlink(SOURCE_APP_NATIVE_TMP);
        return -1;
    }
    return 0;
}

static int replace_started_source(const char *tag, const char *message,
                                  struct yield_result *result,
                                  char *package, size_t package_size) {
    char cached_package[PACKAGE_LENGTH];
    char logged_process[PACKAGE_LENGTH];
    int logged_pid;
    int logged_uid;
    struct timespec start;
    struct timespec end;

    if (strcmp(tag, "ActivityManager") != 0 ||
        strstr(message, "Start proc ") == NULL || !guard_active()) return 0;
    if (parse_started_process(message, &logged_pid, &logged_uid, logged_process,
                              sizeof(logged_process)) != 0) return 0;
    if (read_source_record(&result->pid, &result->uid, cached_package,
                           sizeof(cached_package)) != 0) return 0;
    if (strcmp(logged_process, cached_package) != 0) return 0;
    if (logged_uid != result->uid) return 0;

    result->pid = logged_pid;
    clock_gettime(CLOCK_MONOTONIC, &start);
    result->cpuset_ok = write_pid_file(SOURCE_CPUSET_PROCS, logged_pid);
    result->cpuctl_ok = write_pid_file(SOURCE_CPUCTL_PROCS, logged_pid);
    result->guard_status = send_guard_command("activate", logged_pid, logged_uid);
    clock_gettime(CLOCK_MONOTONIC, &end);
    result->guard_us = timespec_diff_us(&end, &start);
    if (!result->cpuset_ok || !result->cpuctl_ok) result->guard_status = -1;
    result->complete_monotonic_ns =
        (int64_t)end.tv_sec * 1000000000LL + end.tv_nsec;
    result->cgroup_complete_monotonic_ns = result->complete_monotonic_ns;
    if (result->guard_status == 0)
        result->write_us = write_source_record(logged_pid, logged_uid, cached_package);
    snprintf(package, package_size, "%s", cached_package);
    return 1;
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
    list_alloc = (list_alloc_fn)dlsym(library, "android_logger_list_alloc");
    logger_open = (logger_open_fn)dlsym(library, "android_logger_open");
    list_read = (list_read_fn)dlsym(library, "android_logger_list_read");
    list_free = (list_free_fn)dlsym(library, "android_logger_list_free");
    if (list_alloc == NULL || logger_open == NULL || list_read == NULL || list_free == NULL) return 11;

    list = list_alloc(ANDROID_LOG_RDONLY, 1, 0);
    if (list == NULL || logger_open(list, LOG_ID_MAIN) == NULL ||
        logger_open(list, LOG_ID_SYSTEM) == NULL) return 12;

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
        if (message_length >= message_limit) continue;

        {
            char package[PACKAGE_LENGTH] = "";
            if (replace_started_source(tag, message, &yield, package, sizeof(package))) {
                count = snprintf(output, sizeof(output),
                                 "%u.%09u|%d|NativeSourceSpawn|package=%s pid=%d uid=%d nativeGuardStatus=%d nativeGuardUs=%lld sourceRecordStatus=%lld nativeCompleteNs=%lld\n",
                                 entry->sec, entry->nsec, entry->pid, package,
                                 yield.pid, yield.uid, yield.guard_status,
                                 (long long)yield.guard_us,
                                 (long long)yield.write_us,
                                 (long long)yield.complete_monotonic_ns);
                if (count > 0 && (size_t)count < sizeof(output))
                    write_all(output, (size_t)count);
                continue;
            }
        }
        if (!is_relevant(message)) continue;

        if (is_launcher_entry_start(message)) {
            struct timespec observed;
            struct timespec emitted = {(time_t)entry->sec, (long)entry->nsec};
            yield = yield_source_native();
            clock_gettime(CLOCK_REALTIME, &observed);
            yield.delivery_us = timespec_diff_us(&observed, &emitted) -
                                yield.write_us - yield.guard_us;
            if (yield.delivery_us < 0 || yield.delivery_us > 5000000) yield.delivery_us = -1;
            snprintf(suffix, sizeof(suffix),
                     " nativeGuardPid=%d nativeGuardUid=%d nativeGuardStatus=%d nativeGuardUs=%lld nativeGuardCpuset=%d nativeGuardCpuctl=%d nativeDeliveryUs=%lld nativeCompleteNs=%lld",
                     yield.pid, yield.uid, yield.guard_status,
                     (long long)yield.guard_us, yield.cpuset_ok, yield.cpuctl_ok,
                     (long long)yield.delivery_us,
                     (long long)yield.complete_monotonic_ns);
        }

        count = snprintf(output, sizeof(output), "%u.%09u|%d|%s|%s%s\n",
                         entry->sec, entry->nsec, entry->pid, tag, message, suffix);
        if (count > 0 && (size_t)count < sizeof(output)) write_all(output, (size_t)count);
    }

    list_free(list);
    dlclose(library);
    return 0;
}
