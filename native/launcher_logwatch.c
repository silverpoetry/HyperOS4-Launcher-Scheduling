#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define LOG_ID_MAIN 0
#define ANDROID_LOG_RDONLY 1
#define LOG_BUFFER_SIZE 65536

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

        count = snprintf(output, sizeof(output), "%u.%09u|%d|%s|%s\n",
                         entry->sec, entry->nsec, entry->pid, tag, message);
        if (count > 0 && (size_t)count < sizeof(output)) write_all(output, (size_t)count);
    }

    list_free(list);
    dlclose(library);
    return 0;
}
