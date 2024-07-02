# BSD Makefile
# On GNU systems, use bmake.

.MAIN:: all

.ERROR::
	@echo
	@echo 'Build failed.'
	@echo 'Consider setting {LUA,PGSQL,KQUEUE}_{INCDIR,LIBDIR,LIBNAME} variables.'

.ifndef PLATFORM
PLATFORM != uname
.endif

.if $(PLATFORM) == "FreeBSD"
# Default configuration for FreeBSD
LUA_INCDIR ?= /usr/local/include/lua54
LUA_LIBDIR  ?= /usr/local/lib
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
LUA_LIBDIR  ?= /usr/lib
LUA_LIBNAME ?= lua5.4
KQUEUE_LIBNAME ?= kqueue
.elif $(DISTRIBUTION) == "Ubuntu"
# Default configuration for Ubuntu
LUA_INCDIR ?= /usr/include/lua5.4
LUA_LIBDIR  ?= /usr/lib/x86_64-linux-gnu
LUA_LIBNAME ?= lua5.4
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
LUA_LIBNAME ?= lua
PGSQL_LIBNAME ?= pq
KQUEUE_LIBNAME ?= kqueue
LUA_CMD ?= lua

.export LUA_CMD

all:: target/lua-libs target/c-libs/neumond/lkq.so target/c-libs/neumond/nbio.so target/c-libs/neumond/pgeff.so
	@echo
	@echo "# Build complete. See target/lua-libs and target/c-libs directories."
	@echo "#"
	@echo "# Copy the lua and C files to an appropriate location"
	@echo "# or use the following environment variables to"
	@echo "# execute Lua code from the current directory:"
	@echo "#"
	@echo "export LUA_PATH='target/lua-libs/?.lua;;'"
	@echo "export LUA_CPATH='target/c-libs/?.so;;'"
	@echo "#"
	@echo "# Several examples are found in the examples/ directory."
	@echo


target/lua-libs: src/*.lua
	mkdir -p target/lua-libs/neumond
	cp src/*.lua target/lua-libs/neumond/
	touch target/lua-libs

target/c-libs/neumond/lkq.so: target/obj/lkq.o
	mkdir -p target/c-libs/neumond
	cc -shared \
		-o target/c-libs/neumond/lkq.so \
		target/obj/lkq.o \
		$(KQUEUE_LIBDIR:%=-L%) $(KQUEUE_LIBNAME:%=-l%)

target/obj/lkq.o: src/lkq.c
	mkdir -p target/obj
	cc -c -Wall -g -fPIC \
		-o target/obj/lkq.o \
		$(LUA_INCDIR:%=-I%) \
		$(KQUEUE_INCDIR:%=-I%) \
		src/lkq.c

target/c-libs/neumond/nbio.so: target/obj/nbio.o
	mkdir -p target/c-libs/neumond
	cc -shared \
		-o target/c-libs/neumond/nbio.so \
		target/obj/nbio.o

target/obj/nbio.o: src/nbio.c
	mkdir -p target/obj
	cc -c -Wall -g -fPIC \
		-o target/obj/nbio.o \
		$(LUA_INCDIR:%=-I%) \
		src/nbio.c

target/c-libs/neumond/pgeff.so: target/obj/pgeff.o
	mkdir -p target/c-libs/neumond
	cc -shared \
		-o target/c-libs/neumond/pgeff.so \
		target/obj/pgeff.o \
		$(PGSQL_LIBDIR:%=-L%) $(PGSQL_LIBNAME:%=-l%)

target/obj/pgeff.o: src/pgeff.c
	mkdir -p target/obj
	cc -c -Wall -g -fPIC \
		-o target/obj/pgeff.o \
		$(LUA_INCDIR:%=-I%) \
		$(PGSQL_INCDIR:%=-I%) \
		src/pgeff.c

test:: all
	cd testing && ./run-tests.sh

clean::
	rm -Rf target/
