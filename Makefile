# Builds priv/termios_nif.so from c_src/termios.c.
#
# Driven by elixir_make (configured in mix.exs). `mix compile` invokes
# `make all`; `mix clean` invokes `make clean`. ERTS_INCLUDE_DIR is set by
# elixir_make to the headers shipped with the running Erlang runtime.

PRIV_DIR    ?= priv
NIF_SO      = $(PRIV_DIR)/termios_nif.so

# elixir_make exports ERTS_INCLUDE_DIR; fall back to detecting it for the
# case where someone runs `make` directly outside the mix workflow.
ifeq ($(ERTS_INCLUDE_DIR),)
  ERTS_INCLUDE_DIR := $(shell erl -noinput -eval 'io:format("~ts/erts-~ts/include", [code:root_dir(), erlang:system_info(version)]), halt().')
endif

CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter -fPIC
CFLAGS  += -I"$(ERTS_INCLUDE_DIR)"
LDFLAGS ?= -shared

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  LDFLAGS += -undefined dynamic_lookup -flat_namespace
endif

.PHONY: all clean

all: $(NIF_SO)

$(NIF_SO): c_src/termios.c | $(PRIV_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

clean:
	rm -f $(NIF_SO)
