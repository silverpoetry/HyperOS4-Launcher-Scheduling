#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <unistd.h>

static int send_event(int fd, unsigned short type, unsigned short code, int value) {
    struct input_event event;
    memset(&event, 0, sizeof(event));
    gettimeofday(&event.time, NULL);
    event.type = type;
    event.code = code;
    event.value = value;
    return write(fd, &event, sizeof(event)) == sizeof(event) ? 0 : -1;
}

static int find_touchscreen(char *path, size_t path_size) {
    char name_path[128];
    char name[128];
    for (int index = 0; index < 32; ++index) {
        snprintf(name_path, sizeof(name_path), "/sys/class/input/event%d/device/name", index);
        FILE *file = fopen(name_path, "r");
        if (!file) continue;
        name[0] = '\0';
        fgets(name, sizeof(name), file);
        fclose(file);
        name[strcspn(name, "\r\n")] = '\0';
        if (strcmp(name, "NVTCapacitiveTouchScreen") == 0) {
            snprintf(path, path_size, "/dev/input/event%d", index);
            return 0;
        }
    }
    return -1;
}

static int set_slot(int fd, int slot, int tracking_id, int x, int y, int pressure) {
    if (send_event(fd, EV_ABS, ABS_MT_SLOT, slot) < 0) return -1;
    if (tracking_id >= 0 && send_event(fd, EV_ABS, ABS_MT_TRACKING_ID, tracking_id) < 0) return -1;
    if (send_event(fd, EV_ABS, ABS_MT_POSITION_X, x) < 0) return -1;
    if (send_event(fd, EV_ABS, ABS_MT_POSITION_Y, y) < 0) return -1;
    if (send_event(fd, EV_ABS, ABS_MT_TOUCH_MAJOR, 80) < 0) return -1;
    if (send_event(fd, EV_ABS, ABS_MT_PRESSURE, pressure) < 0) return -1;
    return 0;
}

int main(int argc, char **argv) {
    char path[64];
    int duration_ms = argc > 1 ? atoi(argv[1]) : 480;
    if (duration_ms < 200 || duration_ms > 1500) {
        fprintf(stderr, "duration must be between 200 and 1500 ms\n");
        return 2;
    }
    if (find_touchscreen(path, sizeof(path)) < 0) {
        fprintf(stderr, "NVTCapacitiveTouchScreen was not found\n");
        return 3;
    }

    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return 4;
    }
    struct input_absinfo x_info;
    struct input_absinfo y_info;
    if (ioctl(fd, EVIOCGABS(ABS_MT_POSITION_X), &x_info) < 0 ||
        ioctl(fd, EVIOCGABS(ABS_MT_POSITION_Y), &y_info) < 0) {
        fprintf(stderr, "failed to read touchscreen coordinate ranges\n");
        close(fd);
        return 5;
    }

    const int steps = 32;
    const int start_x = x_info.minimum + (x_info.maximum - x_info.minimum) * 8 / 100;
    const int end_x = x_info.minimum + (x_info.maximum - x_info.minimum) * 60 / 100;
    const int y[3] = {
        y_info.minimum + (y_info.maximum - y_info.minimum) * 34 / 100,
        y_info.minimum + (y_info.maximum - y_info.minimum) * 50 / 100,
        y_info.minimum + (y_info.maximum - y_info.minimum) * 66 / 100,
    };

    for (int slot = 0; slot < 3; ++slot) {
        if (set_slot(fd, slot, 1200 + slot, start_x, y[slot], 320) < 0) goto write_error;
    }
    send_event(fd, EV_KEY, BTN_TOOL_FINGER, 1);
    send_event(fd, EV_SYN, SYN_REPORT, 0);
    usleep(24000);

    for (int step = 1; step <= steps; ++step) {
        int x = start_x + (end_x - start_x) * step / steps;
        for (int slot = 0; slot < 3; ++slot) {
            if (set_slot(fd, slot, -1, x, y[slot], 320) < 0) goto write_error;
        }
        send_event(fd, EV_SYN, SYN_REPORT, 0);
        usleep((useconds_t)duration_ms * 1000 / steps);
    }

    for (int slot = 0; slot < 3; ++slot) {
        send_event(fd, EV_ABS, ABS_MT_SLOT, slot);
        send_event(fd, EV_ABS, ABS_MT_TRACKING_ID, -1);
    }
    send_event(fd, EV_KEY, BTN_TOOL_FINGER, 0);
    send_event(fd, EV_SYN, SYN_REPORT, 0);
    close(fd);
    printf("device=%s duration_ms=%d raw_x=%d-%d raw_y=%d,%d,%d\n",
           path, duration_ms, start_x, end_x, y[0], y[1], y[2]);
    return 0;

write_error:
    fprintf(stderr, "write %s: %s\n", path, strerror(errno));
    close(fd);
    return 6;
}
