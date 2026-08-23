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

static int scale_axis(const struct input_absinfo *axis, int percent) {
    return axis->minimum + (axis->maximum - axis->minimum) * percent / 100;
}

static void screen_to_raw(const struct input_absinfo *x_axis,
                          const struct input_absinfo *y_axis,
                          int orientation, int screen_x, int screen_y,
                          int *raw_x, int *raw_y) {
    int x_percent = screen_x;
    int y_percent = screen_y;
    switch (orientation) {
        case 1:
            x_percent = 100 - screen_y;
            y_percent = screen_x;
            break;
        case 2:
            x_percent = 100 - screen_x;
            y_percent = 100 - screen_y;
            break;
        case 3:
            x_percent = screen_y;
            y_percent = 100 - screen_x;
            break;
    }
    *raw_x = scale_axis(x_axis, x_percent);
    *raw_y = scale_axis(y_axis, y_percent);
}

int main(int argc, char **argv) {
    char path[64];
    int duration_ms = argc > 1 ? atoi(argv[1]) : 480;
    int orientation = argc > 2 ? atoi(argv[2]) : 0;
    if (duration_ms < 200 || duration_ms > 1500) {
        fprintf(stderr, "duration must be between 200 and 1500 ms\n");
        return 2;
    }
    if (orientation < 0 || orientation > 3) {
        fprintf(stderr, "orientation must be between 0 and 3\n");
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
    const int finger_x[3] = {34, 50, 66};
    const int start_y = 92;
    const int end_y = 40;
    int raw_x;
    int raw_y;

    for (int slot = 0; slot < 3; ++slot) {
        screen_to_raw(&x_info, &y_info, orientation, finger_x[slot], start_y,
                      &raw_x, &raw_y);
        if (set_slot(fd, slot, 1200 + slot, raw_x, raw_y, 320) < 0) goto write_error;
    }
    send_event(fd, EV_KEY, BTN_TOOL_FINGER, 1);
    send_event(fd, EV_SYN, SYN_REPORT, 0);
    usleep(24000);

    for (int step = 1; step <= steps; ++step) {
        int screen_y = start_y + (end_y - start_y) * step / steps;
        for (int slot = 0; slot < 3; ++slot) {
            screen_to_raw(&x_info, &y_info, orientation, finger_x[slot], screen_y,
                          &raw_x, &raw_y);
            if (set_slot(fd, slot, -1, raw_x, raw_y, 320) < 0) goto write_error;
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
    printf("device=%s duration_ms=%d orientation=%d screen_y=%d-%d\n",
           path, duration_ms, orientation, start_y, end_y);
    return 0;

write_error:
    fprintf(stderr, "write %s: %s\n", path, strerror(errno));
    close(fd);
    return 6;
}
