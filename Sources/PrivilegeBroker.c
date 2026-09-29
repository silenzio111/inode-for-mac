#include "PrivilegeBroker.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t broker_stopping = 0;
static void broker_stop(int signal_number) { (void)signal_number; broker_stopping = 1; }

static int run_command(char *const arguments[]) {
    char *environment[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL};
    pid_t child;
    if (posix_spawn(&child, arguments[0], NULL, NULL, arguments, environment)) return -1;
    int status;
    if (waitpid(child, &status, 0) != child) return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static int snapshot_vendor(const char *helper_path, char *root, size_t capacity,
                           char *template, size_t template_capacity) {
#ifdef INODE_BROKER_TESTING
    (void)helper_path; (void)root; (void)capacity;
    template[0] = 0; (void)template_capacity;
    return 0;
#else
    char executable[1024], source[1200];
    if (!realpath(helper_path, executable)) return -1;
    char *last = strrchr(executable, '/');
    if (!last) return -1;
    *last = 0;
    if (snprintf(source, sizeof(source), "%s/vendor-mac", executable) >= (int)sizeof(source)) return -1;
    const char *pattern = "/private/var/tmp/inode-broker-vendor.XXXXXX";
    if (strlen(pattern) + 1 > capacity) return -1;
    strcpy(root, pattern);
    if (!mkdtemp(root)) return -1;
    if (snprintf(template, template_capacity, "%s/vendor-mac", root) >= (int)template_capacity) return -1;
    char *copy[] = {"/bin/cp", "-R", source, template, NULL};
    if (run_command(copy)) return -1;
    struct stat engine;
    char binary[1300];
    if (snprintf(binary, sizeof(binary), "%s/AuthenMngService", template) >= (int)sizeof(binary) ||
        lstat(binary, &engine) || !S_ISREG(engine.st_mode)) return -1;
    return 0;
#endif
}

static void remove_snapshot(const char *root) {
    if (!root[0]) return;
    char *remove[] = {"/bin/rm", "-rf", (char *)root, NULL};
    run_command(remove);
}

static int child_session(const char *request, uid_t owner, char *session, size_t capacity) {
    struct stat file, directory;
    int fd = open(request, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return 0;
    if (fstat(fd, &file) || !S_ISREG(file.st_mode) || file.st_uid != owner ||
        (file.st_mode & 077) || file.st_size < 2 || file.st_size >= (off_t)capacity) {
        close(fd); unlink(request); return 0;
    }
    FILE *input = fdopen(fd, "r");
    if (!input) { close(fd); unlink(request); return 0; }
    int valid = fgets(session, (int)capacity, input) != NULL;
    int extra = fgetc(input);
    fclose(input); unlink(request);
    if (!valid || extra != EOF) return 0;
    char *end = strchr(session, '\n');
    if (!end || end[1] != 0) return 0;
    *end = 0;
    if (session[0] != '/' || strstr(session, "/../") || strstr(session, "/./") ||
        lstat(session, &directory) || !S_ISDIR(directory.st_mode) ||
        directory.st_uid != owner || (directory.st_mode & 077)) return 0;
    return 1;
}

static void mark_session_finished(const char *session, uid_t owner) {
    int directory = open(session, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (directory < 0) return;
    struct stat details;
    if (!fstat(directory, &details) && S_ISDIR(details.st_mode) &&
        details.st_uid == owner && !(details.st_mode & 077)) {
        int marker = openat(directory, "finished", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (marker >= 0) close(marker);
    }
    close(directory);
}

int privilege_broker_run(const char *directory, const char *parent_text,
                         const char *helper_path, BrokerSessionRunner run_session) {
    struct stat control;
    if (strlen(directory) > 800 || directory[0] != '/' ||
        lstat(directory, &control) || !S_ISDIR(control.st_mode) ||
        control.st_uid == 0 || (control.st_mode & 077)) return 2;
    char *tail = NULL;
    long parsed = strtol(parent_text, &tail, 10);
    if (!tail || *tail || parsed <= 1 || parsed > 2147483647L || kill((pid_t)parsed, 0)) return 2;
    pid_t parent = (pid_t)parsed;
    char snapshot_root[1200] = {0}, vendor_template[1300] = {0};
    if (snapshot_vendor(helper_path, snapshot_root, sizeof(snapshot_root),
                        vendor_template, sizeof(vendor_template))) {
        remove_snapshot(snapshot_root);
        return 2;
    }
    char request[900], ready[900], quit[900];
    snprintf(request, sizeof(request), "%s/request", directory);
    snprintf(ready, sizeof(ready), "%s/ready", directory);
    snprintf(quit, sizeof(quit), "%s/quit", directory);
    int fd = open(ready, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
    if (fd < 0) { remove_snapshot(snapshot_root); return 2; }
    char pid_text[40];
    int count = snprintf(pid_text, sizeof(pid_text), "%ld\n", (long)getpid());
    if (write(fd, pid_text, (size_t)count) != count) {
        close(fd); unlink(ready); remove_snapshot(snapshot_root); return 2;
    }
    close(fd);
    signal(SIGTERM, broker_stop); signal(SIGINT, broker_stop);
    pid_t child = 0;
    char active_session[1024] = {0};
    while (!broker_stopping && access(quit, F_OK) != 0 && kill(parent, 0) == 0) {
        if (child) {
            int status;
            if (waitpid(child, &status, WNOHANG) == child) {
                child = 0;
                mark_session_finished(active_session, control.st_uid);
                active_session[0] = 0;
            }
        }
        if (!child) {
            char session[1024];
            if (child_session(request, control.st_uid, session, sizeof(session))) {
                child = fork();
                if (child == 0) _exit(run_session(session, vendor_template));
                if (child < 0) { child = 0; mark_session_finished(session, control.st_uid); }
                else snprintf(active_session, sizeof(active_session), "%s", session);
            }
        }
        struct timespec pause = {.tv_sec = 0, .tv_nsec = 100000000};
        nanosleep(&pause, NULL);
    }
    if (child) {
        kill(child, SIGTERM);
        for (int i = 0; i < 30; i++) {
            if (waitpid(child, NULL, WNOHANG) == child) { child = 0; break; }
            struct timespec pause = {.tv_sec = 0, .tv_nsec = 100000000};
            nanosleep(&pause, NULL);
        }
        if (child) { kill(child, SIGKILL); waitpid(child, NULL, 0); }
        mark_session_finished(active_session, control.st_uid);
    }
    unlink(request); unlink(ready); unlink(quit); rmdir(directory);
    remove_snapshot(snapshot_root);
    return 0;
}
