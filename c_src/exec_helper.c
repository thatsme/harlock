// harlock_exec — runs one program in the terminal's foreground and reports how
// it ended.
//
// Started by the termios NIF (exec_start_nif) with posix_spawn, as the leader
// of a new process group, with fds 0-2 on the tty, fd 3 on a status pipe, and
// every signal at its default disposition. The NIF then makes that group the
// terminal's foreground.
//
// Why a helper instead of spawning the program directly: the BEAM ignores
// SIGCHLD, so the kernel discards a direct child's exit status and waitpid in
// the VM can never collect it. This process is an ordinary parent, so it can.
//
//   harlock_exec <dir or ""> <program> [args...]
//
// Writes exactly one line to fd 3, then exits 0:
//
//   exited <code>
//   signaled <signal>
//   failed <stage> <errno>      (stage: foreground | chdir | exec | fork | pipe | wait)

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#if defined(__linux__)
#include <dirent.h>
#include <stdlib.h>
#endif

#define STATUS_FD 3

// Signals the helper ignores for itself — it shares the foreground group with
// the program, so Ctrl-C and Ctrl-Z reach it too — and restores to default in
// the program before exec. SIG_IGN survives exec; SIG_DFL is what the program
// must start with.
static const int TERMINAL_SIGNALS[] = {SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU};
#define N_TERMINAL_SIGNALS (sizeof(TERMINAL_SIGNALS) / sizeof(TERMINAL_SIGNALS[0]))

static void report(const char *line) {
    size_t len = strlen(line);
    while (len > 0) {
        ssize_t n = write(STATUS_FD, line, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        line += n;
        len -= (size_t)n;
    }
}

static int report_failure(const char *stage, int err) {
    char line[64];
    snprintf(line, sizeof(line), "failed %s %d\n", stage, err);
    report(line);
    return 0;
}

// posix_spawn on macOS closes everything else (POSIX_SPAWN_CLOEXEC_DEFAULT).
// Linux has no such flag, so descriptors the BEAM left inheritable are closed
// here, before the program could inherit them.
static void close_inherited_fds(void) {
#if defined(__linux__)
    DIR *dir = opendir("/proc/self/fd");
    if (dir) {
        int dir_fd = dirfd(dir);
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            int fd = atoi(entry->d_name);
            if (fd > STATUS_FD && fd != dir_fd) close(fd);
        }
        closedir(dir);
        return;
    }
    for (int fd = STATUS_FD + 1; fd < 4096; fd++) close(fd);
#endif
}

// The NIF calls tcsetpgrp right after spawning us. Starting the program before
// that lands would let its first read hit a background group and stop it with
// SIGTTIN, so wait for it. Bounded, in case the NIF failed and killed nothing.
static int wait_for_foreground(void) {
    struct timespec pause = {0, 2 * 1000 * 1000};
    for (int i = 0; i < 1000; i++) {
        if (tcgetpgrp(STDIN_FILENO) == getpgrp()) return 0;
        nanosleep(&pause, NULL);
    }
    return -1;
}

int main(int argc, char **argv) {
    if (argc < 3) return 2;

    const char *dir = argv[1];
    char **program_argv = argv + 2;

    for (size_t i = 0; i < N_TERMINAL_SIGNALS; i++) signal(TERMINAL_SIGNALS[i], SIG_IGN);

    fcntl(STATUS_FD, F_SETFD, FD_CLOEXEC);
    close_inherited_fds();

    if (wait_for_foreground() != 0) return report_failure("foreground", ETIMEDOUT);

    // The program reports a chdir or exec failure through this pipe. On a
    // successful exec, FD_CLOEXEC closes it and the read below sees EOF.
    int err_pipe[2];
    if (pipe(err_pipe) != 0) return report_failure("pipe", errno);
    fcntl(err_pipe[1], F_SETFD, FD_CLOEXEC);

    pid_t child = fork();
    if (child < 0) return report_failure("fork", errno);

    if (child == 0) {
        close(err_pipe[0]);
        for (size_t i = 0; i < N_TERMINAL_SIGNALS; i++) signal(TERMINAL_SIGNALS[i], SIG_DFL);

        int failure[2] = {0, 0};
        if (dir[0] != '\0' && chdir(dir) != 0) {
            failure[0] = 1;
            failure[1] = errno;
        } else {
            execvp(program_argv[0], program_argv);
            failure[0] = 2;
            failure[1] = errno;
        }
        ssize_t ignored = write(err_pipe[1], failure, sizeof(failure));
        (void)ignored;
        _exit(127);
    }

    close(err_pipe[1]);
    int failure[2];
    ssize_t n;
    do { n = read(err_pipe[0], failure, sizeof(failure)); } while (n < 0 && errno == EINTR);
    close(err_pipe[0]);

    int status;
    for (;;) {
        pid_t r = waitpid(child, &status, WUNTRACED);
        if (r < 0) {
            if (errno == EINTR) continue;
            return report_failure("wait", errno);
        }
        // Stopped by Ctrl-Z (or any stop signal). There is no job table to hand
        // it back to, so it resumes in the foreground.
        if (WIFSTOPPED(status)) {
            kill(child, SIGCONT);
            continue;
        }
        break;
    }

    if (n == (ssize_t)sizeof(failure)) {
        return report_failure(failure[0] == 1 ? "chdir" : "exec", failure[1]);
    }

    char line[64];
    if (WIFEXITED(status)) {
        snprintf(line, sizeof(line), "exited %d\n", WEXITSTATUS(status));
    } else {
        snprintf(line, sizeof(line), "signaled %d\n", WTERMSIG(status));
    }
    report(line);
    return 0;
}
