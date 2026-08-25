#define _GNU_SOURCE

#include "transition_policy.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define LOG_ID_MAIN 0
#define ANDROID_LOG_RDONLY 1
#define LOG_BUFFER_SIZE 65536
#define PACKAGE_LENGTH 256
#define GUARD_SOCKET "/dev/.hyperos4-launcher-scheduling/source-guard.sock"
#define DEFAULT_STATUS "/dev/.hyperos4-launcher-scheduling/coordinator.status"
#define DEFAULT_MODE "/data/adb/modules/hyperos4_recents_source_app_yield/launcher-mode"
#define DEFAULT_SERIAL "/data/adb/modules/hyperos4_recents_source_app_yield/transition.serial"

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

enum phase {
    PHASE_APP,
    PHASE_ENTERING,
    PHASE_HOME,
    PHASE_RECENTS,
    PHASE_LEAVING,
};

enum transaction_kind {
    TRANSACTION_NONE,
    TRANSACTION_ENTRY,
    TRANSACTION_EXIT,
    TRANSACTION_HOME,
};

struct coordinator_config {
    struct transition_policy_config policy;
    int source_enabled;
    unsigned visual_quiet_ms;
    unsigned fallback_ms;
    unsigned reassert_ms;
    char status_path[512];
    char mode_path[512];
    char serial_path[512];
    char initial_source[PACKAGE_LENGTH];
    enum phase initial_phase;
};

struct coordinator {
    pthread_mutex_t lock;
    pthread_mutex_t event_lock;
    pthread_cond_t condition;
    struct coordinator_config config;
    struct transition_policy policy;
    enum phase phase;
    enum transaction_kind transaction_kind;
    uint64_t transition_id;
    unsigned sequence;
    int gesture_active;
    int target_unsuppressed;
    int policy_deadline_valid;
    struct timespec policy_deadline;
    int status_dirty;
    char status_reason[128];
    int stopping;
    pthread_t timer_thread;
    pthread_t watchdog_thread;
    pthread_t reader_thread;
    int monitor_result;
    pid_t launcher_pid;
    unsigned long long launcher_start_time;
    char source_package[PACKAGE_LENGTH];
    uint64_t last_event_written_ns;
    uint64_t last_event_received_ns;
    uint64_t last_event_lag_us;
};

static int guard_socket_fd = -1;

static uint64_t monotonic_ns(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) +
           (uint64_t)value.tv_nsec;
}

static uint64_t realtime_ns(void) {
    struct timespec value;
    clock_gettime(CLOCK_REALTIME, &value);
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) +
           (uint64_t)value.tv_nsec;
}

static struct timespec deadline_after(unsigned milliseconds) {
    uint64_t nanoseconds = monotonic_ns() +
                           (uint64_t)milliseconds * UINT64_C(1000000);
    struct timespec result;
    result.tv_sec = (time_t)(nanoseconds / UINT64_C(1000000000));
    result.tv_nsec = (long)(nanoseconds % UINT64_C(1000000000));
    return result;
}

static int deadline_reached(const struct timespec *deadline) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec > deadline->tv_sec ||
           (now.tv_sec == deadline->tv_sec && now.tv_nsec >= deadline->tv_nsec);
}

static const char *phase_name(enum phase phase) {
    switch (phase) {
        case PHASE_APP: return "app";
        case PHASE_ENTERING: return "entering";
        case PHASE_HOME: return "home";
        case PHASE_RECENTS: return "recents";
        case PHASE_LEAVING: return "leaving";
    }
    return "unknown";
}

static const char *transaction_name(enum transaction_kind kind) {
    switch (kind) {
        case TRANSACTION_NONE: return "none";
        case TRANSACTION_ENTRY: return "entry";
        case TRANSACTION_EXIT: return "exit";
        case TRANSACTION_HOME: return "home";
    }
    return "unknown";
}

static int write_atomic(const char *path, const char *text) {
    char temporary[640];
    int fd;
    size_t length = strlen(text);
    if (snprintf(temporary, sizeof(temporary), "%s.tmp", path) >=
        (int)sizeof(temporary)) return -1;
    fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (write(fd, text, length) != (ssize_t)length) {
        close(fd);
        unlink(temporary);
        return -1;
    }
    if (close(fd) != 0 || rename(temporary, path) != 0) {
        unlink(temporary);
        return -1;
    }
    return 0;
}

static void publish_state_locked(struct coordinator *coordinator,
                                 const char *reason) {
    coordinator->status_dirty = 1;
    snprintf(coordinator->status_reason, sizeof(coordinator->status_reason),
             "%s", reason);
    pthread_cond_signal(&coordinator->condition);
}

static void flush_state_locked(struct coordinator *coordinator) {
    char status[1280];
    char status_path[512];
    char reason[128];
    enum phase phase = coordinator->phase;
    enum transaction_kind transaction_kind = coordinator->transaction_kind;
    uint64_t transition_id = coordinator->transition_id;
    unsigned sequence = coordinator->sequence;
    int policy_active = coordinator->policy.active;
    int policy_deadline = coordinator->policy_deadline_valid;
    unsigned long corrections = coordinator->policy.corrections;
    unsigned long affinity_corrections = coordinator->policy.affinity_corrections;
    unsigned long clamp_corrections = coordinator->policy.clamp_corrections;
    unsigned long launcher_corrections = coordinator->policy.launcher_corrections;
    unsigned long systemui_corrections = coordinator->policy.systemui_corrections;
    unsigned long system_server_corrections = coordinator->policy.system_server_corrections;
    uint64_t last_event_written_ns = coordinator->last_event_written_ns;
    uint64_t last_event_received_ns = coordinator->last_event_received_ns;
    uint64_t last_event_lag_us = coordinator->last_event_lag_us;
    snprintf(status_path, sizeof(status_path), "%s",
             coordinator->config.status_path);
    snprintf(reason, sizeof(reason), "%s", coordinator->status_reason);
    coordinator->status_dirty = 0;
    pthread_mutex_unlock(&coordinator->lock);
    int length = snprintf(
        status, sizeof(status),
        "online=1\ncoordinator_pid=%d\nphase=%s\ntransaction=%s\ntransition_id=%llu\nsequence=%u\npolicy_active=%d\npolicy_deadline=%d\ncorrections=%lu\naffinity_corrections=%lu\nclamp_corrections=%lu\nlauncher_corrections=%lu\nsystemui_corrections=%lu\nsystem_server_corrections=%lu\nlast_event_written_ns=%llu\nlast_event_received_ns=%llu\nlast_event_lag_us=%llu\nreason=%s\n",
        getpid(), phase_name(phase), transaction_name(transaction_kind),
        (unsigned long long)transition_id, sequence,
        policy_active, policy_deadline, corrections, affinity_corrections,
        clamp_corrections, launcher_corrections, systemui_corrections,
        system_server_corrections,
        (unsigned long long)last_event_written_ns,
        (unsigned long long)last_event_received_ns,
        (unsigned long long)last_event_lag_us, reason);
    if (length > 0 && (size_t)length < sizeof(status))
        (void)write_atomic(status_path, status);
    pthread_mutex_lock(&coordinator->lock);
}

static int send_guard(const char *format, ...) {
    struct sockaddr_un address;
    char command[512];
    va_list arguments;
    int length;
    va_start(arguments, format);
    length = vsnprintf(command, sizeof(command), format, arguments);
    va_end(arguments);
    if (length <= 0 || (size_t)length >= sizeof(command)) return -1;
    if (guard_socket_fd < 0) {
        guard_socket_fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
        if (guard_socket_fd < 0) return -1;
        memset(&address, 0, sizeof(address));
        address.sun_family = AF_UNIX;
        snprintf(address.sun_path, sizeof(address.sun_path), "%s", GUARD_SOCKET);
        if (connect(guard_socket_fd, (struct sockaddr *)&address,
                    sizeof(address)) != 0) {
            close(guard_socket_fd);
            guard_socket_fd = -1;
            return -1;
        }
    }
    if (send(guard_socket_fd, command, (size_t)length + 1, 0) < 0) {
        close(guard_socket_fd);
        guard_socket_fd = -1;
        return -1;
    }
    return 0;
}

static void schedule_policy_completion_locked(struct coordinator *coordinator,
                                               unsigned delay_ms,
                                               const char *reason) {
    if (!coordinator->policy.active) {
        coordinator->policy_deadline_valid = 0;
        if (coordinator->transaction_kind == TRANSACTION_EXIT)
            coordinator->phase = PHASE_APP;
        else if (coordinator->phase == PHASE_ENTERING)
            coordinator->phase = PHASE_RECENTS;
        coordinator->transaction_kind = TRANSACTION_NONE;
        if (coordinator->phase == PHASE_APP)
            coordinator->target_unsuppressed = 0;
        publish_state_locked(coordinator, reason);
        return;
    }
    coordinator->policy_deadline = deadline_after(delay_ms);
    coordinator->policy_deadline_valid = 1;
    publish_state_locked(coordinator, reason);
    pthread_cond_signal(&coordinator->condition);
}

static void prepare_transition_locked(struct coordinator *coordinator,
                                      enum transaction_kind kind,
                                      enum phase next) {
    if (coordinator->transaction_kind != kind) {
        coordinator->transition_id = monotonic_ns();
        coordinator->sequence++;
    }
    coordinator->transaction_kind = kind;
    coordinator->policy_deadline_valid = 0;
    coordinator->phase = next;
}

static void begin_policy_locked(struct coordinator *coordinator,
                                enum transaction_kind kind,
                                enum phase next,
                                const char *reason) {
    prepare_transition_locked(coordinator, kind, next);
    (void)transition_policy_begin(&coordinator->policy);
    publish_state_locked(coordinator, reason);
    pthread_cond_signal(&coordinator->condition);
}

static void start_entry(struct coordinator *coordinator, const char *reason) {
    pthread_mutex_lock(&coordinator->lock);
    coordinator->target_unsuppressed = 0;
    prepare_transition_locked(coordinator, TRANSACTION_ENTRY, PHASE_ENTERING);
    if (coordinator->config.source_enabled)
        (void)send_guard("enter %llu",
                         (unsigned long long)coordinator->transition_id);
    (void)transition_policy_begin(&coordinator->policy);
    coordinator->policy_deadline = deadline_after(coordinator->config.fallback_ms);
    coordinator->policy_deadline_valid = 1;
    coordinator->gesture_active = 1;
    publish_state_locked(coordinator, reason);
    pthread_cond_signal(&coordinator->condition);
    pthread_mutex_unlock(&coordinator->lock);
}

static void start_leaving(struct coordinator *coordinator, const char *reason) {
    pthread_mutex_lock(&coordinator->lock);
    if (coordinator->transaction_kind != TRANSACTION_EXIT) {
        prepare_transition_locked(coordinator, TRANSACTION_EXIT, PHASE_LEAVING);
        if (coordinator->config.source_enabled)
            (void)send_guard("enter %llu",
                             (unsigned long long)coordinator->transition_id);
        (void)transition_policy_begin(&coordinator->policy);
    } else {
        (void)transition_policy_begin(&coordinator->policy);
    }
    coordinator->policy_deadline = deadline_after(coordinator->config.fallback_ms);
    coordinator->policy_deadline_valid = 1;
    publish_state_locked(coordinator, reason);
    pthread_cond_signal(&coordinator->condition);
    pthread_mutex_unlock(&coordinator->lock);
}

static void start_home(struct coordinator *coordinator, const char *reason) {
    pthread_mutex_lock(&coordinator->lock);
    prepare_transition_locked(coordinator, TRANSACTION_HOME, PHASE_HOME);
    if (coordinator->config.source_enabled)
        (void)send_guard("enter %llu",
                         (unsigned long long)coordinator->transition_id);
    (void)transition_policy_begin(&coordinator->policy);
    coordinator->gesture_active = 0;
    schedule_policy_completion_locked(coordinator,
                                      coordinator->config.visual_quiet_ms,
                                      reason);
    pthread_mutex_unlock(&coordinator->lock);
}

static void settle_launcher_surface(struct coordinator *coordinator,
                                    enum phase phase, const char *reason,
                                    int finish_gesture) {
    pthread_mutex_lock(&coordinator->lock);
    coordinator->phase = phase;
    if (finish_gesture) coordinator->gesture_active = 0;
    schedule_policy_completion_locked(coordinator,
                                      coordinator->config.visual_quiet_ms,
                                      reason);
    pthread_mutex_unlock(&coordinator->lock);
}

static void handle_launcher_resumed(struct coordinator *coordinator) {
    enum phase phase;
    enum transaction_kind kind;
    pthread_mutex_lock(&coordinator->lock);
    phase = coordinator->phase;
    kind = coordinator->transaction_kind;
    if (kind == TRANSACTION_ENTRY || kind == TRANSACTION_EXIT ||
        phase == PHASE_ENTERING || phase == PHASE_RECENTS ||
        phase == PHASE_LEAVING) {
        publish_state_locked(coordinator, "launcher-resumed-intermediate");
        pthread_mutex_unlock(&coordinator->lock);
        return;
    }
    if (kind == TRANSACTION_HOME || phase == PHASE_HOME) {
        coordinator->phase = PHASE_HOME;
        schedule_policy_completion_locked(coordinator,
                                          coordinator->config.visual_quiet_ms,
                                          "launcher-resumed-home");
        pthread_mutex_unlock(&coordinator->lock);
        return;
    }
    pthread_mutex_unlock(&coordinator->lock);
    start_home(coordinator, "launcher-resumed-home");
}

static void handoff_target(struct coordinator *coordinator,
                           const char *package) {
    int package_changed;
    int same_source;
    pthread_mutex_lock(&coordinator->lock);
    package_changed = coordinator->source_package[0] == '\0' ||
                      strcmp(coordinator->source_package, package) != 0;
    same_source = !coordinator->target_unsuppressed && !package_changed;
    snprintf(coordinator->source_package, sizeof(coordinator->source_package),
             "%s", package);
    if (coordinator->phase == PHASE_APP &&
        coordinator->transaction_kind == TRANSACTION_NONE) {
        uint64_t identity = monotonic_ns();
        coordinator->target_unsuppressed = 0;
        if (coordinator->config.source_enabled)
            (void)send_guard("adopt %llu %s",
                             (unsigned long long)identity, package);
        pthread_mutex_unlock(&coordinator->lock);
        return;
    }
    if (coordinator->transaction_kind != TRANSACTION_EXIT)
        begin_policy_locked(coordinator, TRANSACTION_EXIT, PHASE_LEAVING,
                            "target-resumed");
    if (coordinator->config.source_enabled) {
        if (same_source)
            (void)send_guard("handoff %llu %s",
                             (unsigned long long)coordinator->transition_id,
                             package);
        else
            (void)send_guard("adopt %llu %s",
                             (unsigned long long)coordinator->transition_id,
                             package);
    }
    coordinator->target_unsuppressed = !same_source;
    schedule_policy_completion_locked(coordinator,
                                      coordinator->config.fallback_ms,
                                      "target-resumed-fallback");
    if (coordinator->config.source_enabled && same_source)
        (void)send_guard("complete %llu %u",
                         (unsigned long long)coordinator->transition_id,
                         coordinator->config.fallback_ms);
    pthread_mutex_unlock(&coordinator->lock);
}

static void complete_to_app(struct coordinator *coordinator,
                            const char *reason, int allow_entry_cancel) {
    pthread_mutex_lock(&coordinator->lock);
    if (allow_entry_cancel && coordinator->gesture_active &&
        coordinator->transaction_kind == TRANSACTION_ENTRY)
        coordinator->transaction_kind = TRANSACTION_EXIT;
    if (coordinator->transition_id != 0 &&
        coordinator->transaction_kind == TRANSACTION_EXIT) {
        coordinator->phase = PHASE_LEAVING;
        schedule_policy_completion_locked(coordinator,
                                          coordinator->config.visual_quiet_ms,
                                          reason);
        if (coordinator->config.source_enabled)
            (void)send_guard("complete %llu %u",
                             (unsigned long long)coordinator->transition_id,
                             coordinator->config.visual_quiet_ms);
    }
    coordinator->gesture_active = 0;
    pthread_mutex_unlock(&coordinator->lock);
}

static void handle_overview_toggle(struct coordinator *coordinator) {
    enum phase phase;
    enum transaction_kind kind;
    pthread_mutex_lock(&coordinator->lock);
    phase = coordinator->phase;
    kind = coordinator->transaction_kind;
    pthread_mutex_unlock(&coordinator->lock);
    if (kind == TRANSACTION_EXIT ||
        (kind == TRANSACTION_NONE && phase == PHASE_RECENTS))
        start_leaving(coordinator, "overview-toggle-exit");
    else
        start_entry(coordinator, "overview-toggle-entry");
}

static void *policy_timer_main(void *argument) {
    struct coordinator *coordinator = argument;
    pthread_mutex_lock(&coordinator->lock);
    while (!coordinator->stopping) {
        struct timespec wake;
        if (coordinator->status_dirty) {
            flush_state_locked(coordinator);
            continue;
        }
        if (!coordinator->policy.active) {
            pthread_cond_wait(&coordinator->condition, &coordinator->lock);
            continue;
        }
        wake = deadline_after(coordinator->config.reassert_ms);
        if (coordinator->policy_deadline_valid &&
            (coordinator->policy_deadline.tv_sec < wake.tv_sec ||
             (coordinator->policy_deadline.tv_sec == wake.tv_sec &&
              coordinator->policy_deadline.tv_nsec < wake.tv_nsec)))
            wake = coordinator->policy_deadline;
        (void)pthread_cond_timedwait(&coordinator->condition,
                                     &coordinator->lock, &wake);
        if (coordinator->stopping) break;
        if (coordinator->policy_deadline_valid &&
            deadline_reached(&coordinator->policy_deadline)) {
            transition_policy_complete(&coordinator->policy);
            coordinator->policy_deadline_valid = 0;
            if (coordinator->transaction_kind == TRANSACTION_EXIT)
                coordinator->phase = PHASE_APP;
            else if (coordinator->phase == PHASE_ENTERING)
                coordinator->phase = PHASE_RECENTS;
            coordinator->transaction_kind = TRANSACTION_NONE;
            if (coordinator->phase == PHASE_APP)
                coordinator->target_unsuppressed = 0;
            publish_state_locked(coordinator, "visual-stable");
        } else if (coordinator->policy.active) {
            transition_policy_reassert(&coordinator->policy);
        }
    }
    pthread_mutex_unlock(&coordinator->lock);
    return NULL;
}

static int parse_boolean(const char *value) {
    return strcmp(value, "1") == 0 || strcmp(value, "enabled") == 0 ||
           strcmp(value, "true") == 0;
}

static unsigned parse_unsigned(const char *value, unsigned fallback,
                               unsigned minimum, unsigned maximum) {
    char *end;
    unsigned long parsed = strtoul(value, &end, 10);
    if (end == value || *end != '\0') return fallback;
    if (parsed < minimum) parsed = minimum;
    if (parsed > maximum) parsed = maximum;
    return (unsigned)parsed;
}

static int load_config(const char *path, struct coordinator_config *config) {
    FILE *file = fopen(path, "re");
    char line[1024];
    memset(config, 0, sizeof(*config));
    config->source_enabled = 1;
    config->visual_quiet_ms = 450;
    config->fallback_ms = 2000;
    config->reassert_ms = 20;
    config->initial_phase = PHASE_APP;
    config->policy.frequency_percent = 78;
    snprintf(config->status_path, sizeof(config->status_path), "%s", DEFAULT_STATUS);
    snprintf(config->mode_path, sizeof(config->mode_path), "%s", DEFAULT_MODE);
    snprintf(config->serial_path, sizeof(config->serial_path), "%s", DEFAULT_SERIAL);
    if (file == NULL) return -1;
    while (fgets(line, sizeof(line), file) != NULL) {
        char *equal = strchr(line, '=');
        char *key = line;
        char *value;
        size_t length;
        if (equal == NULL) continue;
        *equal = '\0';
        value = equal + 1;
        length = strcspn(value, "\r\n");
        value[length] = '\0';
#define CONFIG_BOOL(name, field) if (strcmp(key, name) == 0) config->field = parse_boolean(value)
#define CONFIG_UINT(name, field, fallback, minimum, maximum) else if (strcmp(key, name) == 0) config->field = parse_unsigned(value, fallback, minimum, maximum)
        CONFIG_BOOL("source_enabled", source_enabled);
        CONFIG_BOOL("launcher_enabled", policy.launcher_enabled);
        CONFIG_BOOL("systemui_enabled", policy.systemui_enabled);
        CONFIG_BOOL("system_server_enabled", policy.system_server_enabled);
        CONFIG_BOOL("auxiliary_enabled", policy.auxiliary_enabled);
        CONFIG_BOOL("frequency_enabled", policy.frequency_enabled);
        CONFIG_UINT("visual_quiet_ms", visual_quiet_ms, 450, 200, 1000);
        CONFIG_UINT("fallback_ms", fallback_ms, 2000, 500, 5000);
        CONFIG_UINT("reassert_ms", reassert_ms, 20, 10, 100);
        CONFIG_UINT("frequency_percent", policy.frequency_percent, 78, 40, 100);
        CONFIG_UINT("launcher_placement", policy.launcher_placement, 2, 1, 8);
        CONFIG_UINT("raster_placement", policy.raster_placement, 4, 1, 8);
        CONFIG_UINT("resmgr_placement", policy.resmgr_placement, 2, 1, 8);
        CONFIG_UINT("fence_placement", policy.fence_placement, 2, 1, 8);
        CONFIG_UINT("systemui_critical_placement", policy.systemui_critical_placement, 2, 1, 8);
        CONFIG_UINT("systemui_maintenance_placement", policy.systemui_maintenance_placement, 6, 1, 8);
        CONFIG_UINT("system_server_critical_placement", policy.system_server_critical_placement, 2, 1, 8);
        CONFIG_UINT("system_server_snapshot_placement", policy.system_server_snapshot_placement, 6, 1, 8);
        CONFIG_UINT("uclamp_raster", policy.raster_min, 928, 0, 1024);
        CONFIG_UINT("uclamp_ui", policy.ui_min, 768, 0, 1024);
        CONFIG_UINT("uclamp_rust", policy.rust_min, 512, 0, 1024);
        CONFIG_UINT("uclamp_resmgr", policy.resmgr_min, 384, 0, 1024);
        else if (strncmp(key, "mask_", 5) == 0) {
            int index = atoi(key + 5);
            if (index >= 1 && index <= POLICY_MASK_COUNT)
                config->policy.masks[index - 1] = strtoull(value, NULL, 16);
        } else if (strcmp(key, "status_path") == 0)
            snprintf(config->status_path, sizeof(config->status_path), "%s", value);
        else if (strcmp(key, "mode_path") == 0)
            snprintf(config->mode_path, sizeof(config->mode_path), "%s", value);
        else if (strcmp(key, "serial_path") == 0)
            snprintf(config->serial_path, sizeof(config->serial_path), "%s", value);
        else if (strcmp(key, "initial_source") == 0)
            snprintf(config->initial_source, sizeof(config->initial_source),
                     "%s", value);
        else if (strcmp(key, "initial_phase") == 0) {
            if (strcmp(value, "home") == 0) config->initial_phase = PHASE_HOME;
            else if (strcmp(value, "recents") == 0)
                config->initial_phase = PHASE_RECENTS;
            else config->initial_phase = PHASE_APP;
        }
#undef CONFIG_BOOL
#undef CONFIG_UINT
    }
    fclose(file);
    for (int i = 0; i < POLICY_MASK_COUNT; ++i)
        if (config->policy.masks[i] == 0) return -1;
    return 0;
}

static int is_protected_package(const char *package) {
    return strcmp(package, "com.miui.home") == 0 ||
           strcmp(package, "com.android.systemui") == 0 ||
           strcmp(package, "com.miui.miwallpaper") == 0;
}

static void handle_event(struct coordinator *coordinator,
                         const char *message) {
    pthread_mutex_lock(&coordinator->lock);
    int stopping = coordinator->stopping;
    pthread_mutex_unlock(&coordinator->lock);
    if (stopping) return;
    if (strstr(message, "activityResumed pkg=") != NULL) {
        const char *start = strstr(message, "activityResumed pkg=") +
                            strlen("activityResumed pkg=");
        char package[PACKAGE_LENGTH];
        size_t length = strcspn(start, ", \t\r\n");
        if (length == 0 || length >= sizeof(package)) return;
        memcpy(package, start, length);
        package[length] = '\0';
        if (strcmp(package, "com.miui.home") == 0) {
            handle_launcher_resumed(coordinator);
        } else if (!is_protected_package(package)) {
            handoff_target(coordinator, package);
        }
        return;
    }
    if (strstr(message, "onOverviewToggle is_home_and_overview_same=true") != NULL) {
        handle_overview_toggle(coordinator);
    } else if (strstr(message, "SceneAnimationSignalType.gestureStart") != NULL ||
        strstr(message, "on_animation_start called type: CloseApp") != NULL) {
        start_entry(coordinator, "launcher-entry");
    } else if (strstr(message, "SceneAnimationSignalType.gestureToHome") != NULL) {
        settle_launcher_surface(coordinator, PHASE_HOME, "gesture-home", 1);
    } else if (strstr(message, "enterOverviewState") != NULL) {
        settle_launcher_surface(coordinator, PHASE_RECENTS,
                                "overview-stable", 1);
    } else if (strstr(message, "exitOverviewState") != NULL &&
               strstr(message, "-> CurrentScene.home") != NULL) {
        start_home(coordinator, "overview-to-home");
    } else if (strstr(message, "exitOverviewState") != NULL ||
               strstr(message, "openingRemoteAnimationOpen") != NULL) {
        start_leaving(coordinator, "launcher-exit");
    } else if (strstr(message, "openingRemoteAnimationClose") != NULL ||
               strstr(message, "finish_remote_transition to_home = false") != NULL) {
        complete_to_app(coordinator, "launcher-exit-complete", 0);
    } else if (strstr(message, "SceneAnimationSignalType.gestureToApp") != NULL ||
               (strstr(message, "IRecentsAnimationRunnerImplForRemoteBack") != NULL &&
                strstr(message, "on_animation_canceled") != NULL)) {
        pthread_mutex_lock(&coordinator->lock);
        int cancel = coordinator->gesture_active;
        pthread_mutex_unlock(&coordinator->lock);
        if (cancel)
            complete_to_app(coordinator, "launcher-entry-canceled", 1);
    }
}

static int is_relevant(const char *tag, const char *message) {
    if (strcmp(tag, "flutter") == 0) {
        if (strstr(message,
                   "SceneTransitionDetectorService detectSceneTransition:") == NULL)
            return 0;
        return strstr(message, "SceneAnimationSignalType.gestureStart") != NULL ||
               strstr(message, "SceneAnimationSignalType.gestureToHome") != NULL ||
               strstr(message, "SceneAnimationSignalType.gestureToApp") != NULL ||
               strstr(message, "SceneAnimationSignalType.enterOverviewState") != NULL ||
               strstr(message, "SceneAnimationSignalType.exitOverviewState") != NULL ||
               strstr(message, "SceneAnimationSignalType.openingRemoteAnimationOpen") != NULL ||
               strstr(message, "SceneAnimationSignalType.openingRemoteAnimationClose") != NULL;
    }
    if (strcmp(tag, "hyper_launcher_app") != 0) return 0;
    return strstr(message, "activityResumed pkg=") != NULL ||
           strstr(message, "finish_remote_transition to_home = false") != NULL ||
           strstr(message, "onOverviewToggle is_home_and_overview_same=true") != NULL ||
           strstr(message, "IRecentsAnimationRunnerImplForRemoteBack") != NULL;
}

static void move_to_foreground(void) {
    (void)proc_move_controller(getpid(), "/dev/cpuset", "/top-app");
    (void)proc_move_controller(getpid(), "/dev/cpuctl", "/foreground");
}

static void pin_controller_to_efficiency_cpu(
    const struct transition_policy_config *config) {
    uint64_t mask = config->masks[POLICY_MASK_COUNT - 1];
    uint64_t single = mask & (~mask + 1);
    if (single != 0) (void)proc_set_affinity(getpid(), single);
}

static void pin_log_reader_to_secondary_cpu(
    const struct transition_policy_config *config) {
    uint64_t mask = config->masks[5];
    pid_t tid = gettid();
    if (mask != 0) (void)proc_set_affinity(tid, mask);
    (void)setpriority(PRIO_PROCESS, (id_t)tid, -5);
}

static void *launcher_watchdog_main(void *argument) {
    struct coordinator *coordinator = argument;
    const struct timespec interval = {.tv_sec = 1, .tv_nsec = 0};
    while (1) {
        int stopping;
        (void)nanosleep(&interval, NULL);
        pthread_mutex_lock(&coordinator->lock);
        stopping = coordinator->stopping;
        pthread_mutex_unlock(&coordinator->lock);
        if (stopping) break;
        if (proc_start_time(coordinator->launcher_pid) !=
            coordinator->launcher_start_time) {
            (void)kill(getpid(), SIGTERM);
            break;
        }
    }
    return NULL;
}

static int monitor_logs(struct coordinator *coordinator) {
    unsigned char raw[LOG_BUFFER_SIZE];
    void *library = dlopen("liblog.so", RTLD_NOW | RTLD_LOCAL);
    list_alloc_fn list_alloc;
    logger_open_fn logger_open;
    list_read_fn list_read;
    list_free_fn list_free;
    logger_list *list;
    if (library == NULL) return 10;
    list_alloc = (list_alloc_fn)dlsym(library, "android_logger_list_alloc");
    logger_open = (logger_open_fn)dlsym(library, "android_logger_open");
    list_read = (list_read_fn)dlsym(library, "android_logger_list_read");
    list_free = (list_free_fn)dlsym(library, "android_logger_list_free");
    if (list_alloc == NULL || logger_open == NULL || list_read == NULL ||
        list_free == NULL) {
        dlclose(library);
        return 11;
    }
    list = list_alloc(ANDROID_LOG_RDONLY, 1, coordinator->launcher_pid);
    if (list == NULL) {
        dlclose(library);
        return 12;
    }
    if (logger_open(list, LOG_ID_MAIN) == NULL) {
        list_free(list);
        dlclose(library);
        return 12;
    }
    while (1) {
        int stopping;
        pthread_mutex_lock(&coordinator->lock);
        stopping = coordinator->stopping;
        pthread_mutex_unlock(&coordinator->lock);
        if (stopping) break;
        int result = list_read(list, raw);
        struct logger_entry_v4 *entry;
        unsigned char *payload;
        const char *tag;
        const char *message;
        size_t tag_length;
        size_t limit;
        if (result <= 0) {
            if (errno == EINTR) continue;
            break;
        }
        if ((size_t)result < sizeof(*entry)) continue;
        entry = (struct logger_entry_v4 *)raw;
        if (entry->hdr_size < 20 || entry->hdr_size >= (uint16_t)result ||
            (size_t)entry->hdr_size + entry->len > (size_t)result)
            continue;
        payload = raw + entry->hdr_size;
        if (entry->len < 3) continue;
        tag = (const char *)(payload + 1);
        tag_length = strnlen(tag, entry->len - 1);
        if (tag_length >= entry->len - 1) continue;
        message = tag + tag_length + 1;
        limit = entry->len - tag_length - 2;
        if (strnlen(message, limit) >= limit ||
            !is_relevant(tag, message)) continue;
        {
            uint64_t written_ns = (uint64_t)entry->sec * UINT64_C(1000000000) +
                                  (uint64_t)entry->nsec;
            uint64_t received_ns = realtime_ns();
            pthread_mutex_lock(&coordinator->lock);
            coordinator->last_event_written_ns = written_ns;
            coordinator->last_event_received_ns = received_ns;
            coordinator->last_event_lag_us =
                received_ns >= written_ns ?
                (received_ns - written_ns) / UINT64_C(1000) : 0;
            pthread_mutex_unlock(&coordinator->lock);
        }
        pthread_mutex_lock(&coordinator->event_lock);
        handle_event(coordinator, message);
        pthread_mutex_unlock(&coordinator->event_lock);
    }
    list_free(list);
    dlclose(library);
    return 0;
}

static void *log_reader_main(void *argument) {
    struct coordinator *coordinator = argument;
    pin_log_reader_to_secondary_cpu(&coordinator->config.policy);
    int result = monitor_logs(coordinator);
    pthread_mutex_lock(&coordinator->lock);
    coordinator->monitor_result = result;
    pthread_mutex_unlock(&coordinator->lock);
    (void)kill(getpid(), SIGTERM);
    return NULL;
}

int main(int argc, char **argv) {
    struct coordinator coordinator;
    pthread_condattr_t condition_attributes;
    sigset_t termination_signals;
    int termination_signal;
    int result;
    int timer_started = 0;
    int watchdog_started = 0;
    if (argc != 2) {
        fprintf(stderr, "usage: %s CONFIG\n", argv[0]);
        return 2;
    }
    memset(&coordinator, 0, sizeof(coordinator));
    if (load_config(argv[1], &coordinator.config) != 0) return 3;
    sigemptyset(&termination_signals);
    sigaddset(&termination_signals, SIGTERM);
    sigaddset(&termination_signals, SIGINT);
    if (pthread_sigmask(SIG_BLOCK, &termination_signals, NULL) != 0)
        return 8;
    coordinator.launcher_pid = proc_find_exact("com.miui.home");
    coordinator.launcher_start_time = proc_start_time(coordinator.launcher_pid);
    if (coordinator.launcher_pid <= 1 || coordinator.launcher_start_time == 0)
        return 5;
    pthread_mutex_init(&coordinator.lock, NULL);
    pthread_mutex_init(&coordinator.event_lock, NULL);
    pthread_condattr_init(&condition_attributes);
    pthread_condattr_setclock(&condition_attributes, CLOCK_MONOTONIC);
    pthread_cond_init(&coordinator.condition, &condition_attributes);
    pthread_condattr_destroy(&condition_attributes);
    coordinator.phase = coordinator.config.initial_phase;
    snprintf(coordinator.source_package, sizeof(coordinator.source_package),
             "%s", coordinator.config.initial_source);
    move_to_foreground();
    pin_controller_to_efficiency_cpu(&coordinator.config.policy);
    transition_policy_initialize(&coordinator.policy, &coordinator.config.policy);
    if (coordinator.phase == PHASE_RECENTS &&
        coordinator.config.source_enabled &&
        coordinator.source_package[0] != '\0') {
        coordinator.transition_id = monotonic_ns();
        (void)send_guard("enter %llu",
                         (unsigned long long)coordinator.transition_id);
    }
    pthread_mutex_lock(&coordinator.lock);
    publish_state_locked(&coordinator, "ready");
    pthread_mutex_unlock(&coordinator.lock);
    if (pthread_create(&coordinator.timer_thread, NULL, policy_timer_main,
                       &coordinator) != 0) {
        result = 4;
        goto cleanup;
    }
    timer_started = 1;
    if (pthread_create(&coordinator.watchdog_thread, NULL,
                       launcher_watchdog_main, &coordinator) != 0) {
        result = 6;
        goto cleanup;
    }
    watchdog_started = 1;
    if (pthread_create(&coordinator.reader_thread, NULL,
                       log_reader_main, &coordinator) != 0) {
        result = 7;
        goto cleanup;
    }
    (void)pthread_detach(coordinator.reader_thread);
    (void)sigwait(&termination_signals, &termination_signal);
    (void)termination_signal;
    pthread_mutex_lock(&coordinator.lock);
    result = coordinator.monitor_result;
    pthread_mutex_unlock(&coordinator.lock);
cleanup:
    pthread_mutex_lock(&coordinator.lock);
    coordinator.stopping = 1;
    pthread_cond_signal(&coordinator.condition);
    pthread_mutex_unlock(&coordinator.lock);
    /* Wait for an event that passed the stopping check before teardown. */
    pthread_mutex_lock(&coordinator.event_lock);
    pthread_mutex_unlock(&coordinator.event_lock);
    if (timer_started) pthread_join(coordinator.timer_thread, NULL);
    if (watchdog_started) pthread_join(coordinator.watchdog_thread, NULL);
    transition_policy_destroy(&coordinator.policy);
    {
        char final_value[128];
        snprintf(final_value, sizeof(final_value), "%s\n",
                 phase_name(coordinator.phase));
        (void)write_atomic(coordinator.config.mode_path, final_value);
        snprintf(final_value, sizeof(final_value), "%u\n",
                 coordinator.sequence);
        (void)write_atomic(coordinator.config.serial_path, final_value);
    }
    if (guard_socket_fd >= 0) close(guard_socket_fd);
    unlink(coordinator.config.status_path);
    /* The detached log reader may still be blocked inside liblog. Returning
     * from main terminates the process and releases its socket. It observes
     * stopping before dispatching any newly received record, so policy
     * teardown above cannot race with another transition. */
    return result;
}
