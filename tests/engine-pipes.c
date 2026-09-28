#include "../Sources/EnginePipes.h"
#include <assert.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

int main(void) {
    char directory[] = "/tmp/inode-engine-pipes-XXXXXX";
    assert(mkdtemp(directory));
    char client[256], command[256], stop[256];
    snprintf(client, sizeof(client), "%s/iNodeClient", directory);
    snprintf(command, sizeof(command), "%s/iNodeCmn", directory);
    snprintf(stop, sizeof(stop), "%s/stop", directory);
    int gate[2];
    assert(pipe(gate) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        close(gate[1]);
        assert(mkfifo(client, 0600) == 0);
        usleep(150000); // The reply pipe exists before the command pipe.
        assert(mkfifo(command, 0600) == 0);
        usleep(250000); // The command pipe exists before its reader.
        int reader = open(command, O_RDONLY | O_NONBLOCK);
        assert(reader >= 0);
        char signal_byte;
        assert(read(gate[0], &signal_byte, 1) == 1);
        close(reader);
        close(gate[0]);
        _exit(0);
    }
    close(gate[0]);
    volatile sig_atomic_t stopped = 0;
    int rx = -1, tx = -1;
    struct timespec before, after;
    assert(clock_gettime(CLOCK_MONOTONIC, &before) == 0);
    assert(engine_pipes_wait(client, command, stop, &child, &stopped, 3, &rx, &tx) == ENGINE_PIPES_READY);
    assert(clock_gettime(CLOCK_MONOTONIC, &after) == 0);
    assert(rx >= 0 && tx >= 0);
    assert((after.tv_sec - before.tv_sec) * 1000000000L + after.tv_nsec - before.tv_nsec >= 300000000L);
    close(rx); close(tx);
    assert(write(gate[1], "x", 1) == 1);
    close(gate[1]);
    assert(waitpid(child, NULL, 0) == child);

    child = fork();
    assert(child >= 0);
    if (child == 0) _exit(0);
    rx = tx = -1;
    assert(engine_pipes_wait(client, command, stop, &child, &stopped, 2, &rx, &tx) == ENGINE_PIPES_ENGINE_EXITED);
    assert(child == 0);
    if (rx >= 0) close(rx);
    if (tx >= 0) close(tx);
    assert(unlink(client) == 0 && unlink(command) == 0 && rmdir(directory) == 0);
    puts("Delayed FIFO creation and reader readiness are retried; engine exit is reported");
}
