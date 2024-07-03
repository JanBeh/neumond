# BSD Makefile
# On GNU systems, use bmake.

.MAIN: .PHONY all

.ERROR: .PHONY
	@echo
	@echo 'Build failed.'
	@echo 'Check Makefile.options and/or set appropriate
	@echo 'environment variables or command line options.'

.ifndef PLATFORM
PLATFORM != uname
.endif

.if $(PLATFORM) == "FreeBSD"

# Default configuration for FreeBSD
LUA_INCDIR ?= /usr/local/include/lua54
#LUA_LIBDIR  ?= /usr/local/lib
LUA_LIBNAME ?= lua-5.4
LUA_CMD ?= lua54
PGSQL_INCDIR ?= /usr/local/include
PGSQL_LIBDIR  ?= /usr/local/lib
KQUEUE_LIBNAME ?=

.elif $(PLATFORM) == "Linux"

# Distinguish between different Linux distributions
.ifndef DISTRIBUTION
DISTRIBUTION != lsb_release -i -s
.endif

.if $(DISTRIBUTION) == "Debian" || $(DISTRIBUTION) == "Raspbian"

# Default configuration for Debian
LUA_INCDIR ?= /usr/include/lua5.4
#LUA_LIBDIR  ?= /usr/lib
LUA_LIBNAME ?= lua5.4
LUA_CMD ?= lua5.4
KQUEUE_LIBNAME ?= kqueue

.elif $(DISTRIBUTION) == "Ubuntu"

# Default configuration for Ubuntu
LUA_INCDIR ?= /usr/include/lua5.4
#LUA_LIBDIR  ?= /usr/lib/x86_64-linux-gnu
LUA_LIBNAME ?= lua5.4
LUA_CMD ?= lua5.4
PGSQL_INCDIR ?= /usr/include
PGSQL_LIBDIR  ?= /usr/lib/x86_64-linux-gnu
KQUEUE_LIBDIR ?= -I /usr/include/kqueue
KQUEUE_LIBNAME ?= kqueue

.else
.warning Could not determine Linux distribution.
.endif

.else
.warning Could not determine Platform.
.endif

# Default configuration (uses libkqueue by default)
LUA_INCDIR ?=
#LUA_LIBDIR ?=
LUA_LIBNAME ?= lua
LUA_CMD ?= lua
PGSQL_INCDIR ?=
PGSQL_LIBDIR ?=
PGSQL_LIBNAME ?= pq
KQUEUE_INCDIR ?=
KQUEUE_LIBDIR ?=
KQUEUE_LIBNAME ?= kqueue
CC ?= cc
CC_LINK_LIB_ARGS ?= -shared -Wall
CC_COMPILE_OBJ_ARGS ?= -c -Wall -O2 -fPIC

.include "Makefile.options"

# Name of Lua command, e.g. lua:
LUA_FILES != cd src && ls *.lua

.export LUA_CMD

all: .PHONY \
		$(LUA_FILES:%=target/neumond/%) \
		target/neumond/lkq.so \
		target/neumond/nbio.so \
		target/neumond/pgeff.so
	@echo
	@echo "# Build complete. See target/neumond directory."
	@echo "# Several examples are found in the examples/ directory."
	@echo

.for LUA_FILE in $(LUA_FILES)
target/neumond/$(LUA_FILE): src/$(LUA_FILE)
	mkdir -p target/neumond
	cp src/$(LUA_FILE) target/neumond/$(LUA_FILE)
.endfor

target/neumond/lkq.so: target/_obj/lkq.o
	mkdir -p target/neumond
	$(CC) $(CC_LINK_LIB_ARGS) \
		-o target/neumond/lkq.so \
		target/_obj/lkq.o \
		$(KQUEUE_LIBDIR:%=-L%) $(KQUEUE_LIBNAME:%=-l%)

target/_obj/lkq.o: src/lkq.c
	mkdir -p target/_obj
	$(CC) $(CC_COMPILE_OBJ_ARGS) \
		-o target/_obj/lkq.o \
		$(LUA_INCDIR:%=-I%) \
		$(KQUEUE_INCDIR:%=-I%) \
		src/lkq.c

target/neumond/nbio.so: target/_obj/nbio.o
	mkdir -p target/neumond
	$(CC) $(CC_LINK_LIB_ARGS) \
		-o target/neumond/nbio.so \
		target/_obj/nbio.o

target/_obj/nbio.o: src/nbio.c
	mkdir -p target/_obj
	$(CC) $(CC_COMPILE_OBJ_ARGS) \
		-o target/_obj/nbio.o \
		$(LUA_INCDIR:%=-I%) \
		src/nbio.c

target/neumond/pgeff.so: target/_obj/pgeff.o
	mkdir -p target/neumond
	$(CC) $(CC_LINK_LIB_ARGS) \
		-o target/neumond/pgeff.so \
		target/_obj/pgeff.o \
		$(PGSQL_LIBDIR:%=-L%) $(PGSQL_LIBNAME:%=-l%)

target/_obj/pgeff.o: src/pgeff.c
	mkdir -p target/_obj
	$(CC) $(CC_COMPILE_OBJ_ARGS) \
		-o target/_obj/pgeff.o \
		$(LUA_INCDIR:%=-I%) \
		$(PGSQL_INCDIR:%=-I%) \
		src/pgeff.c

test: .PHONY all
	cd testing && ./run-tests.sh

clean: .PHONY
	rm -Rf target/
