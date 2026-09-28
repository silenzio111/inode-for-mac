#include "EnginePipes.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int try_open_fifo(const char *path, int flags) {
    struct stat file;
    if (lstat(path, &file)) return errno == ENOENT || errno == EINTR ? -1 : -2;
    if (!S_ISFIFO(file.st_mode)) return -2;
    int fd = open(path, flags | O_NONBLOCK | O_NOFOLLOW);
    if (fd >= 0) return fd;
    return errno == ENOENT || errno == ENXIO || errno == EINTR ? -1 : -2;
}

EnginePipesResult engine_pipes_wait(const char *client_path, const char *command_path,
                                    const char *stop_path, pid_t *engine_pid,
                                    volatile sig_atomic_t *stopped, int timeout_seconds,
                                    int *client_fd, int *command_fd) {
    struct timespec start, now;
    if (clock_gettime(CLOCK_MONOTONIC, &start) || timeout_seconds <= 0) return ENGINE_PIPES_ERROR;
    for (;;) {
        if (*stopped || access(stop_path, F_OK) == 0) return ENGINE_PIPES_STOPPED;
        if (*engine_pid > 0) {
            int status;
            pid_t observed = waitpid(*engine_pid, &status, WNOHANG);
            if (observed == *engine_pid || (observed < 0 && errno == ECHILD)) {
                *engine_pid = 0;
                return ENGINE_PIPES_ENGINE_EXITED;
            }
            if (observed < 0 && errno != EINTR) return ENGINE_PIPES_ERROR;
        }
        if (*client_fd < 0) {
            int fd = try_open_fifo(client_path, O_RDWR);
            if (fd == -2) return ENGINE_PIPES_ERROR;
            if (fd >= 0) *client_fd = fd;
        }
        if (*command_fd < 0) {
            int fd = try_open_fifo(command_path, O_WRONLY);
            if (fd == -2) return ENGINE_PIPES_ERROR;
            if (fd >= 0) *command_fd = fd;
        }
        if (*client_fd >= 0 && *command_fd >= 0) return ENGINE_PIPES_READY;
        if (clock_gettime(CLOCK_MONOTONIC, &now)) return ENGINE_PIPES_ERROR;
        if (now.tv_sec - start.tv_sec >= timeout_seconds) return ENGINE_PIPES_TIMEOUT;
        struct timespec pause = {.tv_sec = 0, .tv_nsec = 100000000};
        nanosleep(&pause, NULL);
    }
}
