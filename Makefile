# Builds priv/termios_nif.so from c_src/termios.c, and priv/harlock_exec — the
# helper the NIF starts to run a program in the terminal's foreground — from
# c_src/exec_helper.c.
#
# Driven by elixir_make (configured in mix.exs). `mix compile` invokes
# `make all`; `mix clean` invokes `make clean`. ERTS_INCLUDE_DIR is set by
# elixir_make to the headers shipped with the running Erlang runtime.

PRIV_DIR    ?= priv
NIF_SO      = $(PRIV_DIR)/termios_nif.so
EXEC_HELPER = $(PRIV_DIR)/harlock_exec

# Cross toolchains (Nerves among them) export CROSSCOMPILE. Where it matters
# below, that flag distinguishes the build host from the target — `uname` and
# the host's `erl` describe the former and must not be allowed to speak for the
# latter.

# elixir_make exports ERTS_INCLUDE_DIR; fall back to detecting it for the case
# where someone runs `make` directly outside the mix workflow. Cross builds get
# an error instead of a guess: the host's headers would silently produce a NIF
# linked against the wrong ERTS, which fails at load time on the device rather
# than here.
ifeq ($(ERTS_INCLUDE_DIR),)
  ifeq ($(CROSSCOMPILE),)
    ERTS_INCLUDE_DIR := $(shell erl -noinput -eval 'io:format("~ts/erts-~ts/include", [code:root_dir(), erlang:system_info(version)]), halt().')
  else
    $(error ERTS_INCLUDE_DIR must be set when cross-compiling — refusing to fall back to the build host's Erlang headers)
  endif
endif

# -fPIC is appended rather than defaulted: a caller-supplied CFLAGS replaces the
# default wholesale, and a shared object without it does not link.
CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter
CFLAGS  += -fPIC -I"$(ERTS_INCLUDE_DIR)"
LDFLAGS ?= -shared

# The helper is an executable, so it takes neither -shared nor the Mach-O
# dynamic_lookup flags below.
HELPER_CFLAGS ?= -O2 -Wall -Wextra

# Darwin needs Mach-O linker flags — but only when Darwin is the *target*.
# Cross-compiling from a Mac to ARM Linux is the common Nerves setup, and
# feeding these to a Linux link breaks it.
ifeq ($(CROSSCOMPILE),)
  UNAME_S := $(shell uname -s)
  ifeq ($(UNAME_S),Darwin)
    LDFLAGS += -undefined dynamic_lookup -flat_namespace
  endif
endif

.PHONY: all clean

all: $(NIF_SO) $(EXEC_HELPER)

$(NIF_SO): c_src/termios.c | $(PRIV_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

$(EXEC_HELPER): c_src/exec_helper.c | $(PRIV_DIR)
	$(CC) $(HELPER_CFLAGS) -o $@ $<

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

clean:
	rm -f $(NIF_SO) $(EXEC_HELPER)
