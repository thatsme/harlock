// Harlock termios NIF.
//
// Direct POSIX termios + TIOCGWINSZ access on /dev/tty. Bypasses the
// `:os.cmd` path entirely — `:os.cmd` spawns subprocesses via the
// erl_child_setup helper which calls setsid(), detaching them from the
// BEAM's controlling terminal. From inside the BEAM process itself we
// retain access to /dev/tty, so termios calls work here.
//
// All NIFs are dirty (ERL_NIF_DIRTY_JOB_IO_BOUND) because tcsetattr can
// block on some pty implementations.

#include <erl_nif.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

static ErlNifResourceType *TTY_FD_TYPE;

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
    {"read_nonblock_nif", 2, read_nonblock_nif, ERL_NIF_DIRTY_JOB_IO_BOUND}};

ERL_NIF_INIT(Elixir.Harlock.Terminal.Termios, nif_funcs, on_load, NULL, NULL,
             NULL);
