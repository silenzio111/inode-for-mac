#ifndef INODE_ENGINE_PIPES_H
#define INODE_ENGINE_PIPES_H

#include <signal.h>
#include <sys/types.h>

typedef enum {
    ENGINE_PIPES_READY,
    ENGINE_PIPES_TIMEOUT,
    ENGINE_PIPES_ENGINE_EXITED,
    ENGINE_PIPES_STOPPED,
    ENGINE_PIPES_ERROR
} EnginePipesResult;

EnginePipesResult engine_pipes_wait(const char *client_path, const char *command_path,
                                    const char *stop_path, pid_t *engine_pid,
                                    volatile sig_atomic_t *stopped, int timeout_seconds,
                                    int *client_fd, int *command_fd);

#endif
