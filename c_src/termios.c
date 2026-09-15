// Harlock termios NIF.
//
// Direct POSIX termios + TIOCGWINSZ access on /dev/tty. Bypasses the
// `:os.cmd` path entirely — `:os.cmd` spawns subprocesses via the
// erl_child_setup helper which calls setsid(), detaching them from the
// BEAM's controlling terminal. From inside the BEAM process itself we
// retain access to /dev/tty, so termios calls work here.
//
// The NIFs are dirty (ERL_NIF_DIRTY_JOB_IO_BOUND) because tcsetattr can block
// on some pty implementations — all but arm_select and exec_arm, which must run
// on a normal scheduler so enif_select_read targets the calling process (see
// the table at the end).
//
// The exec_* NIFs hand the terminal to another program. Programs the BEAM
// starts through ports get no controlling terminal (see above), so the
// program is started from here instead, via the harlock_exec helper, as the
// terminal's foreground process group — the way a shell runs a job.

#include <erl_nif.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

extern char **environ;

static ErlNifResourceType *TTY_FD_TYPE;
static ErlNifResourceType *EXEC_TYPE;

// A program started by exec_start_nif. `status_fd` is the read end of the
// helper's status pipe; `pgid` is the helper's process group, which the
// program shares.
typedef struct {
    int status_fd;
    pid_t pgid;
    int finished;
    // Status lines arrive whole, but a read can return more than one — a stop
    // and the exit right after it — so they are split here, one per call.
    char buf[256];
    int len;
} exec_t;

typedef struct {
    int fd;
    ErlNifPid owner;
} tty_fd_t;

static int owner_matches(ErlNifEnv *env, tty_fd_t *tty) {
    ErlNifPid caller;
    enif_self(env, &caller);
    return enif_compare_pids(&caller, &tty->owner) == 0;
}

// Called when the resource is GC'd OR when enif_select marks the fd as
// stopped. We must not close from the destructor if a select is still
// active — enif_select_read with stop tells us when it's safe via a
// stop callback. Simpler: register a stop callback that closes the fd
// once BEAM has finished its select bookkeeping.

static void tty_fd_stop(ErlNifEnv *env, void *obj, ErlNifEvent fd,
                        int is_direct_call) {
    (void)env;
    (void)obj;
    (void)is_direct_call;
    // BEAM has unregistered fd from its poller; safe to close.
    close(fd);
}

static void tty_fd_destructor(ErlNifEnv *env, void *obj) {
    tty_fd_t *tty = (tty_fd_t *)obj;
    if (tty->fd >= 0) {
        // Mark fd as stopped; BEAM calls tty_fd_stop when select bookkeeping
        // is done, which closes the fd. Marking is idempotent if we already
        // stopped it explicitly.
        enif_select(env, tty->fd, ERL_NIF_SELECT_STOP, obj, NULL,
                    enif_make_atom(env, "undefined"));
        tty->fd = -1;
    }
}

static void exec_stop(ErlNifEnv *env, void *obj, ErlNifEvent fd,
                      int is_direct_call) {
    (void)env;
    (void)obj;
    (void)is_direct_call;
    close(fd);
}

// A program whose resource is collected before it finished is killed, so a
// crashed owner cannot leave it holding the terminal. Only while unfinished:
// once the helper has reported, the group id may already belong to someone
// else.
static void exec_destructor(ErlNifEnv *env, void *obj) {
    exec_t *ex = (exec_t *)obj;
    if (!ex->finished && ex->pgid > 0) kill(-ex->pgid, SIGKILL);
    if (ex->status_fd >= 0) {
        enif_select(env, ex->status_fd, ERL_NIF_SELECT_STOP, obj, NULL,
                    enif_make_atom(env, "undefined"));
        ex->status_fd = -1;
    }
}

static int on_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data;
    (void)load_info;
    ErlNifResourceTypeInit init = {
        .dtor = tty_fd_destructor,
        .stop = tty_fd_stop,
        .members = 2,
    };
    TTY_FD_TYPE = enif_open_resource_type_x(
        env, "harlock_tty_fd", &init,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
    if (TTY_FD_TYPE == NULL) return -1;

    ErlNifResourceTypeInit exec_init = {
        .dtor = exec_destructor,
        .stop = exec_stop,
        .members = 2,
    };
    EXEC_TYPE = enif_open_resource_type_x(
        env, "harlock_exec", &exec_init,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);
    if (EXEC_TYPE == NULL) return -1;
    return 0;
}

static ERL_NIF_TERM make_error(ErlNifEnv *env, const char *atom) {
    return enif_make_tuple2(
        env, enif_make_atom(env, "error"), enif_make_atom(env, atom));
}

static ERL_NIF_TERM make_error_errno(ErlNifEnv *env, int err) {
    const char *atom;
    switch (err) {
        case ENXIO:   atom = "no_tty"; break;
        case EACCES:  atom = "permission_denied"; break;
        case ENOENT:  atom = "no_device"; break;
        case EBADF:   atom = "bad_fd"; break;
        case ENOTTY:  atom = "not_a_tty"; break;
        case EINTR:   atom = "interrupted"; break;
        default:      atom = "errno"; break;
    }
    if (!strcmp(atom, "errno")) {
        return enif_make_tuple2(
            env, enif_make_atom(env, "error"),
            enif_make_tuple2(env, enif_make_atom(env, "errno"),
                             enif_make_int(env, err)));
    }
    return make_error(env, atom);
}

// open() -> {:ok, ref} | {:error, reason}
// Opens /dev/tty with O_NONBLOCK so read(2) returns EAGAIN instead of
// blocking when no data is available. Pair with arm_select/1 for
// readiness notifications.
static ERL_NIF_TERM open_nif(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;

    int fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        return make_error_errno(env, errno);
    }
    if (!isatty(fd)) {
        close(fd);
        return make_error(env, "not_a_tty");
    }

    tty_fd_t *tty = enif_alloc_resource(TTY_FD_TYPE, sizeof(tty_fd_t));
    tty->fd = fd;
    enif_self(env, &tty->owner);
    ERL_NIF_TERM ref = enif_make_resource(env, tty);
    enif_release_resource(tty);

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), ref);
}

// close(ref) -> :ok
// Uses ERL_NIF_SELECT_STOP so BEAM unregisters the fd from its poller
// before the actual close(2) happens (via the stop callback).
static ERL_NIF_TERM close_nif(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
    (void)argc;
    tty_fd_t *tty;
    if (!enif_get_resource(env, argv[0], TTY_FD_TYPE, (void **)&tty)) {
        return enif_make_badarg(env);
    }
    if (tty->fd >= 0) {
        enif_select(env, tty->fd, ERL_NIF_SELECT_STOP, tty, NULL,
                    enif_make_atom(env, "undefined"));
        tty->fd = -1;
    }
    return enif_make_atom(env, "ok");
}

// get(ref) -> {:ok, binary} | {:error, reason}
// The binary is the raw `struct termios` bytes — opaque to Elixir, used
// only as input to a subsequent set/2.
static ERL_NIF_TERM get_nif(ErlNifEnv *env, int argc,
                            const ERL_NIF_TERM argv[]) {
    (void)argc;
    tty_fd_t *tty;
    if (!enif_get_resource(env, argv[0], TTY_FD_TYPE, (void **)&tty)) {
        return enif_make_badarg(env);
    }
    if (tty->fd < 0) return make_error(env, "closed");

    struct termios t;
    if (tcgetattr(tty->fd, &t) < 0) {
        return make_error_errno(env, errno);
    }

    ErlNifBinary bin;
    if (!enif_alloc_binary(sizeof(t), &bin)) {
        return make_error(env, "alloc");
    }
    memcpy(bin.data, &t, sizeof(t));

    return enif_make_tuple2(
        env, enif_make_atom(env, "ok"), enif_make_binary(env, &bin));
}

// set(ref, binary) -> :ok | {:error, reason}
static ERL_NIF_TERM set_nif(ErlNifEnv *env, int argc,
                            const ERL_NIF_TERM argv[]) {
    (void)argc;
    tty_fd_t *tty;
    if (!enif_get_resource(env, argv[0], TTY_FD_TYPE, (void **)&tty)) {
        return enif_make_badarg(env);
    }
    if (tty->fd < 0) return make_error(env, "closed");

    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[1], &bin)) {
        return enif_make_badarg(env);
    }
    if (bin.size != sizeof(struct termios)) {
        return make_error(env, "bad_size");
    }

    struct termios t;
    memcpy(&t, bin.data, sizeof(t));

    if (tcsetattr(tty->fd, TCSANOW, &t) < 0) {
        return make_error_errno(env, errno);
    }
    return enif_make_atom(env, "ok");
}

// set_raw(ref) -> :ok | {:error, reason}
// cfmakeraw + VMIN=1, VTIME=0 (block for one byte, no inter-byte timer).
static ERL_NIF_TERM set_raw_nif(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
    (void)argc;
    tty_fd_t *tty;
    if (!enif_get_resource(env, argv[0], TTY_FD_TYPE, (void **)&tty)) {
        return enif_make_badarg(env);
    }
    if (tty->fd < 0) return make_error(env, "closed");

    struct termios t;
    if (tcgetattr(tty->fd, &t) < 0) {
        return make_error_errno(env, errno);
    }

    cfmakeraw(&t);
    t.c_cc[VMIN] = 1;
    t.c_cc[VTIME] = 0;

    if (tcsetattr(tty->fd, TCSANOW, &t) < 0) {
        return make_error_errno(env, errno);
    }
    return enif_make_atom(env, "ok");
}

// winsize(ref) -> {:ok, {rows, cols}} | {:error, reason}
static ERL_NIF_TERM winsize_nif(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
    (void)argc;
    tty_fd_t *tty;
    if (!enif_get_resource(env, argv[0], TTY_FD_TYPE, (void **)&tty)) {
        return enif_make_badarg(env);
    }
    if (tty->fd < 0) return make_error(env, "closed");

    struct winsize ws;
    if (ioctl(tty->fd, TIOCGWINSZ, &ws) < 0) {
        return make_error_errno(env, errno);
    }

    ERL_NIF_TERM size =
        enif_make_tuple2(env, enif_make_uint(env, ws.ws_row),
                         enif_make_uint(env, ws.ws_col));
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), size);
}

// arm_select(ref) -> :ok | {:error, reason}
// Registers the fd with the BEAM IO poller for read-ready events. When
// the fd becomes readable, BEAM sends {:tty_ready, ref} to the calling
// process. One-shot: each notification consumes the registration, so
// the caller re-arms after every read. The message is delivered to the
// calling process (pid=NULL).
static ERL_NIF_TERM arm_select_nif(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc;
    tty_fd_t *tty;
    if (!enif_get_resource(env, argv[0], TTY_FD_TYPE, (void **)&tty)) {
        return enif_make_badarg(env);
    }
    if (tty->fd < 0) return make_error(env, "closed");
    if (!owner_matches(env, tty)) return make_error(env, "not_owner");

    ErlNifEnv *msg_env = enif_alloc_env();
    ERL_NIF_TERM msg =
        enif_make_tuple2(msg_env, enif_make_atom(msg_env, "tty_ready"),
                         enif_make_copy(msg_env, argv[0]));

    int rc = enif_select_read(env, tty->fd, tty, NULL, msg, msg_env);

    // On success, BEAM takes ownership of msg_env. On failure, we own it
    // and must free.
    if (rc < 0) {
        enif_free_env(msg_env);
        return make_error(env, "select_failed");
    }

    return enif_make_atom(env, "ok");
}

// read_nonblock(ref, max_bytes) -> {:ok, binary} | :wouldblock | :eof |
//                                  {:error, reason}
// Non-blocking read(2) on the fd (the fd was opened with O_NONBLOCK).
// Returns :wouldblock if no data was ready (caller should re-arm select
// and wait). Otherwise returns whatever bytes were available.
static ERL_NIF_TERM read_nonblock_nif(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
    (void)argc;
    tty_fd_t *tty;
    if (!enif_get_resource(env, argv[0], TTY_FD_TYPE, (void **)&tty)) {
        return enif_make_badarg(env);
    }
    if (tty->fd < 0) return make_error(env, "closed");
    if (!owner_matches(env, tty)) return make_error(env, "not_owner");

    unsigned max;
    if (!enif_get_uint(env, argv[1], &max)) return enif_make_badarg(env);
    if (max == 0 || max > 65536) return enif_make_badarg(env);

    ErlNifBinary bin;
    if (!enif_alloc_binary(max, &bin)) return make_error(env, "alloc");

    ssize_t n;
    do {
        n = read(tty->fd, bin.data, max);
    } while (n < 0 && errno == EINTR);

    if (n < 0) {
        enif_release_binary(&bin);
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return enif_make_atom(env, "wouldblock");
        }
        return make_error_errno(env, errno);
    }
    if (n == 0) {
        enif_release_binary(&bin);
        return enif_make_atom(env, "eof");
    }

    if ((size_t)n < bin.size) {
        enif_realloc_binary(&bin, n);
    }
    return enif_make_tuple2(env, enif_make_atom(env, "ok"),
                            enif_make_binary(env, &bin));
}

// -- Handing the terminal to another program --------------------------------

static const char *errno_atom(int err) {
    switch (err) {
        case ENOENT:    return "enoent";
        case EACCES:    return "eacces";
        case ENOTDIR:   return "enotdir";
        case ENOEXEC:   return "enoexec";
        case ENOMEM:    return "enomem";
        case E2BIG:     return "e2big";
        case EAGAIN:    return "eagain";
        case ETIMEDOUT: return "etimedout";
        case EPERM:     return "eperm";
        case EIO:       return "eio";
        default:        return NULL;
    }
}

static ERL_NIF_TERM errno_term(ErlNifEnv *env, int err) {
    const char *name = errno_atom(err);
    if (name) return enif_make_atom(env, name);
    return enif_make_tuple2(env, enif_make_atom(env, "errno"), enif_make_int(env, err));
}

static ERL_NIF_TERM error2(ErlNifEnv *env, const char *what, int err) {
    return enif_make_tuple2(
        env, enif_make_atom(env, "error"),
        enif_make_tuple2(env, enif_make_atom(env, what), errno_term(env, err)));
}

static char *dup_binary(ErlNifEnv *env, ERL_NIF_TERM term) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin)) return NULL;
    if (memchr(bin.data, '\0', bin.size)) return NULL;
    char *s = enif_alloc(bin.size + 1);
    memcpy(s, bin.data, bin.size);
    s[bin.size] = '\0';
    return s;
}

// A NULL-terminated array of C strings from a list of binaries, with `prefix`
// leading entries left for the caller to fill. NULL on a malformed list.
static char **dup_binary_list(ErlNifEnv *env, ERL_NIF_TERM list, unsigned prefix,
                              unsigned *count) {
    unsigned len;
    if (!enif_get_list_length(env, list, &len)) return NULL;
    char **out = enif_alloc(sizeof(char *) * (prefix + len + 1));
    memset(out, 0, sizeof(char *) * (prefix + len + 1));
    ERL_NIF_TERM head, tail = list;
    for (unsigned i = 0; i < len; i++) {
        enif_get_list_cell(env, tail, &head, &tail);
        if ((out[prefix + i] = dup_binary(env, head)) == NULL) {
            for (unsigned j = prefix; j < prefix + i; j++) enif_free(out[j]);
            enif_free(out);
            return NULL;
        }
    }
    *count = prefix + len;
    return out;
}

static void free_strings(char **strings, unsigned from, unsigned count) {
    if (!strings) return;
    for (unsigned i = from; i < count; i++) enif_free(strings[i]);
    enif_free(strings);
}

// Duplicate `fd` to a number above 3 with FD_CLOEXEC, closing the original.
// The helper's fd 3 is the status pipe; a source descriptor that happened to
// be 3 already would make that dup2 a no-op and leave FD_CLOEXEC set on it.
static int move_high_cloexec(int fd) {
    int high = fcntl(fd, F_DUPFD_CLOEXEC, 10);
    int saved = errno;
    close(fd);
    errno = saved;
    return high;
}

// exec_start(tty_ref, helper_path, dir, argv, env) ->
//     {:ok, exec_ref, os_pid} | {:error, reason}
//
// `argv` is a non-empty list of binaries, program first; `dir` is "" for the
// current directory; `env` is a list of "KEY=VALUE" binaries, or nil to
// inherit. The caller must be in the terminal's foreground group.
static ERL_NIF_TERM exec_start_nif(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc;
    tty_fd_t *tty;
    if (!enif_get_resource(env, argv[0], TTY_FD_TYPE, (void **)&tty)) {
        return enif_make_badarg(env);
    }
    if (tty->fd < 0) return make_error(env, "closed");

    // tcsetpgrp from a background group would stop the BEAM; refuse instead.
    if (tcgetpgrp(tty->fd) != getpgrp()) return make_error(env, "not_foreground");

    char *helper = dup_binary(env, argv[1]);
    char *dir = dup_binary(env, argv[2]);
    unsigned argv_count = 0, env_count = 0;
    char **helper_argv = dup_binary_list(env, argv[3], 2, &argv_count);
    char **envp = NULL;
    int env_ok = enif_is_atom(env, argv[4]) ||
                 (envp = dup_binary_list(env, argv[4], 0, &env_count)) != NULL;

    ERL_NIF_TERM result;
    if (!helper || !dir || !helper_argv || argv_count < 3 || !env_ok) {
        result = enif_make_badarg(env);
        goto done;
    }
    helper_argv[0] = helper;
    helper_argv[1] = dir;

    // A fresh descriptor for the program: the Reader's is O_NONBLOCK, and a
    // dup2 of it would hand the program a non-blocking stdin.
    int child_tty = open("/dev/tty", O_RDWR | O_NOCTTY);
    if (child_tty < 0) { result = error2(env, "open_tty", errno); goto done; }
    if ((child_tty = move_high_cloexec(child_tty)) < 0) {
        result = error2(env, "open_tty", errno);
        goto done;
    }

    int status_pipe[2];
    if (pipe(status_pipe) != 0) {
        result = error2(env, "pipe", errno);
        close(child_tty);
        goto done;
    }
    status_pipe[0] = move_high_cloexec(status_pipe[0]);
    status_pipe[1] = move_high_cloexec(status_pipe[1]);
    if (status_pipe[0] < 0 || status_pipe[1] < 0) {
        result = error2(env, "pipe", errno);
        if (status_pipe[0] >= 0) close(status_pipe[0]);
        if (status_pipe[1] >= 0) close(status_pipe[1]);
        close(child_tty);
        goto done;
    }
    fcntl(status_pipe[0], F_SETFL, O_NONBLOCK);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, child_tty, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, child_tty, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, child_tty, STDERR_FILENO);
    posix_spawn_file_actions_adddup2(&actions, status_pipe[1], 3);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t defaults, empty;
    sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL);
    sigdelset(&defaults, SIGSTOP);
    sigemptyset(&empty);
    posix_spawnattr_setsigdefault(&attr, &defaults);
    posix_spawnattr_setsigmask(&attr, &empty);
    posix_spawnattr_setpgroup(&attr, 0);
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    posix_spawnattr_setflags(&attr, flags);

    pid_t pid;
    int rc = posix_spawn(&pid, helper, &actions, &attr, helper_argv,
                         envp ? envp : environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(child_tty);
    close(status_pipe[1]);

    if (rc != 0) {
        close(status_pipe[0]);
        result = error2(env, "spawn", rc);
        goto done;
    }

    if (tcsetpgrp(tty->fd, pid) != 0) {
        int err = errno;
        kill(-pid, SIGKILL);
        close(status_pipe[0]);
        result = error2(env, "foreground", err);
        goto done;
    }

    exec_t *ex = enif_alloc_resource(EXEC_TYPE, sizeof(exec_t));
    ex->status_fd = status_pipe[0];
    ex->pgid = pid;
    ex->finished = 0;
    ex->len = 0;
    ERL_NIF_TERM ref = enif_make_resource(env, ex);
    enif_release_resource(ex);
    result = enif_make_tuple3(env, enif_make_atom(env, "ok"), ref, enif_make_int(env, pid));

done:
    // helper_argv[0..1] are `helper` and `dir`; free those separately.
    if (helper_argv) free_strings(helper_argv, 2, argv_count);
    free_strings(envp, 0, env_count);
    if (helper) enif_free(helper);
    if (dir) enif_free(dir);
    return result;
}

// exec_arm(exec_ref) -> :ok | {:error, reason}
// One-shot readiness on the status pipe: the caller receives
// {:exec_ready, exec_ref} when the helper has reported or died.
static ERL_NIF_TERM exec_arm_nif(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    (void)argc;
    exec_t *ex;
    if (!enif_get_resource(env, argv[0], EXEC_TYPE, (void **)&ex)) {
        return enif_make_badarg(env);
    }
    if (ex->status_fd < 0) return make_error(env, "closed");

    ErlNifEnv *msg_env = enif_alloc_env();
    ERL_NIF_TERM msg =
        enif_make_tuple2(msg_env, enif_make_atom(msg_env, "exec_ready"),
                         enif_make_copy(msg_env, argv[0]));
    if (enif_select_read(env, ex->status_fd, ex, NULL, msg, msg_env) < 0) {
        enif_free_env(msg_env);
        return make_error(env, "select_failed");
    }
    return enif_make_atom(env, "ok");
}

static void exec_finish(ErlNifEnv *env, exec_t *ex) {
    ex->finished = 1;
    if (ex->status_fd >= 0) {
        enif_select(env, ex->status_fd, ERL_NIF_SELECT_STOP, ex, NULL,
                    enif_make_atom(env, "undefined"));
        ex->status_fd = -1;
    }
}

// exec_read(exec_ref) ->
//     {:stopped, signal} | {:exited, code} | {:signaled, signal} |
//     {:failed, stage, errno} | :killed | :wouldblock | {:error, reason}
//
// One status line per call. {:stopped, signal} is not final: the program is
// stopped and the pipe stays open, so the caller re-arms and reads again.
// :killed means the helper died without reporting — its process group was
// killed. Any other result is final and closes the pipe.
static ERL_NIF_TERM exec_read_nif(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    (void)argc;
    exec_t *ex;
    if (!enif_get_resource(env, argv[0], EXEC_TYPE, (void **)&ex)) {
        return enif_make_badarg(env);
    }
    if (ex->status_fd < 0) return make_error(env, "closed");

    char *newline = memchr(ex->buf, '\n', ex->len);
    int eof = 0;

    // Read only when no whole line is already buffered: a line read earlier
    // would otherwise sit unreported with nothing left in the pipe to wake the
    // caller.
    if (!newline) {
        ssize_t n;
        do {
            n = read(ex->status_fd, ex->buf + ex->len, sizeof(ex->buf) - 1 - ex->len);
        } while (n < 0 && errno == EINTR);

        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return enif_make_atom(env, "wouldblock");
            int err = errno;
            exec_finish(env, ex);
            return make_error_errno(env, err);
        }
        if (n == 0) eof = 1;
        ex->len += (int)n;
        newline = memchr(ex->buf, '\n', ex->len);
    }

    if (!newline) {
        if (eof) {
            exec_finish(env, ex);
            return ex->len == 0 ? enif_make_atom(env, "killed") : make_error(env, "bad_status");
        }
        return enif_make_atom(env, "wouldblock");
    }

    char line[256];
    int line_len = (int)(newline - ex->buf);
    memcpy(line, ex->buf, line_len);
    line[line_len] = '\0';
    ex->len -= line_len + 1;
    memmove(ex->buf, newline + 1, ex->len);

    int value, err;
    char stage[24];
    if (sscanf(line, "stopped %d", &value) == 1) {
        return enif_make_tuple2(env, enif_make_atom(env, "stopped"), enif_make_int(env, value));
    }

    exec_finish(env, ex);
    if (sscanf(line, "exited %d", &value) == 1) {
        return enif_make_tuple2(env, enif_make_atom(env, "exited"), enif_make_int(env, value));
    }
    if (sscanf(line, "signaled %d", &value) == 1) {
        return enif_make_tuple2(env, enif_make_atom(env, "signaled"), enif_make_int(env, value));
    }
    if (sscanf(line, "failed %23s %d", stage, &err) == 2) {
        return enif_make_tuple3(env, enif_make_atom(env, "failed"),
                                enif_make_atom(env, stage), errno_term(env, err));
    }
    return make_error(env, "bad_status");
}

// exec_continue(tty_ref, exec_ref) -> :ok | {:error, reason}
//
// Give the terminal's foreground back to a stopped program's process group and
// send it SIGCONT. The caller holds the foreground (after its own resume, the
// shell gives it to this BEAM); SIGTTOU is blocked anyway, as in reclaim.
static ERL_NIF_TERM exec_continue_nif(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
    (void)argc;
    tty_fd_t *tty;
    exec_t *ex;
    if (!enif_get_resource(env, argv[0], TTY_FD_TYPE, (void **)&tty) ||
        !enif_get_resource(env, argv[1], EXEC_TYPE, (void **)&ex)) {
        return enif_make_badarg(env);
    }
    if (tty->fd < 0) return make_error(env, "closed");
    if (ex->finished) return make_error(env, "finished");

    sigset_t block, saved;
    sigemptyset(&block);
    sigaddset(&block, SIGTTOU);
    pthread_sigmask(SIG_BLOCK, &block, &saved);
    int rc = tcsetpgrp(tty->fd, ex->pgid);
    int err = errno;
    pthread_sigmask(SIG_SETMASK, &saved, NULL);

    if (rc != 0 && err != EPERM) return make_error_errno(env, err);
    if (kill(-ex->pgid, SIGCONT) != 0 && errno != ESRCH) return make_error_errno(env, errno);
    return enif_make_atom(env, "ok");
}

// exec_kill(exec_ref) -> :ok | {:error, :finished}
// SIGKILL to the whole process group: the helper and the program.
static ERL_NIF_TERM exec_kill_nif(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    (void)argc;
    exec_t *ex;
    if (!enif_get_resource(env, argv[0], EXEC_TYPE, (void **)&ex)) {
        return enif_make_badarg(env);
    }
    if (ex->finished) return make_error(env, "finished");
    if (kill(-ex->pgid, SIGKILL) != 0 && errno != ESRCH) return make_error_errno(env, errno);
    return enif_make_atom(env, "ok");
}

// reclaim(tty_ref) -> :ok | {:error, reason}
//
// Make the BEAM's process group the terminal's foreground again. After a
// program ran, the BEAM is a background group, and tcsetpgrp from there
// raises SIGTTOU — which stops the whole VM under a job-control shell, and OTP
// cannot handle it. Blocking it in this thread is enough: the kernel checks
// the calling thread's mask.
static ERL_NIF_TERM reclaim_nif(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
    (void)argc;
    tty_fd_t *tty;
    if (!enif_get_resource(env, argv[0], TTY_FD_TYPE, (void **)&tty)) {
        return enif_make_badarg(env);
    }
    if (tty->fd < 0) return make_error(env, "closed");

    sigset_t block, saved;
    sigemptyset(&block);
    sigaddset(&block, SIGTTOU);
    pthread_sigmask(SIG_BLOCK, &block, &saved);
    int rc = tcsetpgrp(tty->fd, getpgrp());
    int err = errno;
    pthread_sigmask(SIG_SETMASK, &saved, NULL);

    return rc == 0 ? enif_make_atom(env, "ok") : make_error_errno(env, err);
}

// job_control(tty_ref) -> boolean
//
// Whether stopping this BEAM would hand the terminal back to a shell that can
// resume it. The kernel discards SIGTSTP sent to an orphaned process group —
// one with no member whose parent is in another group of the same session —
// and nothing would ever send the SIGCONT. So: this BEAM holds the foreground,
// and job_shell/0 holds.
static int parent_is_job_shell(void) {
    pid_t parent = getppid();
    return getsid(parent) == getsid(0) && getpgid(parent) != getpgrp();
}

static ERL_NIF_TERM job_control_nif(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
    (void)argc;
    tty_fd_t *tty;
    if (!enif_get_resource(env, argv[0], TTY_FD_TYPE, (void **)&tty)) {
        return enif_make_badarg(env);
    }
    if (tty->fd < 0) return make_error(env, "closed");

    int ok = tcgetpgrp(tty->fd) == getpgrp() && parent_is_job_shell();
    return enif_make_atom(env, ok ? "true" : "false");
}

// job_shell() -> boolean
//
// The parent half of job_control/1 alone: this BEAM's parent is in the same
// session under a different process group, as an interactive shell running it
// as a job is. For when the BEAM does not hold the foreground — a program
// started by exec_start does.
static ERL_NIF_TERM job_shell_nif(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    return enif_make_atom(env, parent_is_job_shell() ? "true" : "false");
}

// suspend() -> :ok | {:error, reason}
// SIGTSTP to this BEAM's process group, as Ctrl-Z would send it. The caller
// sets SIGTSTP to its default disposition first and checks job_control/1.
static ERL_NIF_TERM suspend_nif(ErlNifEnv *env, int argc,
                                const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    if (kill(0, SIGTSTP) != 0) return make_error_errno(env, errno);
    return enif_make_atom(env, "ok");
}

// foreground(tty_ref) -> boolean
static ERL_NIF_TERM foreground_nif(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc;
    tty_fd_t *tty;
    if (!enif_get_resource(env, argv[0], TTY_FD_TYPE, (void **)&tty)) {
        return enif_make_badarg(env);
    }
    if (tty->fd < 0) return make_error(env, "closed");
    return enif_make_atom(env, tcgetpgrp(tty->fd) == getpgrp() ? "true" : "false");
}

static ErlNifFunc nif_funcs[] = {
    {"open_nif",          0, open_nif,          ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close_nif",         1, close_nif,         ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"get_nif",           1, get_nif,           ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"set_nif",           2, set_nif,           ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"set_raw_nif",       1, set_raw_nif,       ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"winsize_nif",       1, winsize_nif,       ERL_NIF_DIRTY_JOB_IO_BOUND},
    // arm_select needs to run on a normal scheduler (not dirty) because
    // enif_select_read requires the calling process to be the receiver.
    {"arm_select_nif",    1, arm_select_nif,    0},
    {"read_nonblock_nif", 2, read_nonblock_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"exec_start_nif",    5, exec_start_nif,    ERL_NIF_DIRTY_JOB_IO_BOUND},
    // Same constraint as arm_select: the caller is the notification target.
    {"exec_arm_nif",      1, exec_arm_nif,      0},
    {"exec_read_nif",     1, exec_read_nif,     ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"exec_kill_nif",     1, exec_kill_nif,     ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"reclaim_nif",       1, reclaim_nif,       ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"foreground_nif",    1, foreground_nif,    ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"job_control_nif",   1, job_control_nif,   ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"suspend_nif",       0, suspend_nif,       ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"exec_continue_nif", 2, exec_continue_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"job_shell_nif",     0, job_shell_nif,     ERL_NIF_DIRTY_JOB_IO_BOUND}};

ERL_NIF_INIT(Elixir.Harlock.Terminal.Termios, nif_funcs, on_load, NULL, NULL,
             NULL);
