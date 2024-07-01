# BSD Makefile
# On GNU systems, use bmake.

.DEFAULT:: all
	@echo "#"
	@echo "# For testing, you may use the following environment variables:"
	@echo "#"
	@echo "export LUA_PATH='target/lua-libs/?.lua;;'"
	@echo "export LUA_CPATH='target/c-libs/?.so;;'"
	@echo "#"
	@echo "# Several examples are found in the examples/ directory."

.DELETE_ON_ERROR::

.ERROR::
	@echo '#'
	@echo '# Build failed. Consider setting the following variables:'
	@echo '#'
	@echo '# LUA_INCLUDE e.g. to "/usr/include"'
	@echo '# LUA_LIBDIR e.g. to "/usr/lib"'
	@echo '# LUA_LIBRARY e.g. to "lua" (for liblua)'
	@echo '# PGSQL_INCLUDE e.g. to "/usr/include"'
	@echo '# PGSQL_LIBDIR e.g. to "/usr/lib"'
	@echo '# PGSQL_LIBRARY e.g. to "pq" (for libpq)'
	@echo '# KQUEUE_INCLUDE_FLAGS e.g. to "" or "-I/usr/include"'
	@echo '# KQUEUE_FLAGS e.g. to "" or "-lkqueue"'
	@echo '#'

.ifndef PLATFORM
PLATFORM != uname
.endif

.if $(PLATFORM) == "FreeBSD"
# Default configuration for FreeBSD
LUA_INCLUDE ?= /usr/local/include/lua54
LUA_LIBDIR  ?= /usr/local/lib
LUA_LIBRARY ?= lua-5.4
PGSQL_INCLUDE ?= /usr/local/include
PGSQL_LIBDIR  ?= /usr/local/lib
PGSQL_LIBRARY ?= pq
KQUEUE_FLAGS ?=
LUA_CMD ?= lua54

.elif $(PLATFORM) == "Linux"
# Distinguish between different Linux distributions
.ifndef DISTRIBUTION
DISTRIBUTION != lsb_release -i -s
.endif
.if $(DISTRIBUTION) == "Debian" || $(DISTRIBUTION) == "Raspbian"
# Default configuration for Debian
LUA_INCLUDE ?= /usr/include/lua5.4
LUA_LIBDIR  ?= /usr/lib
LUA_LIBRARY ?= lua5.4
PGSQL_INCLUDE ?= /usr/include
PGSQL_LIBDIR  ?= /usr/lib
PGSQL_LIBRARY ?= pq
KQUEUE_FLAGS ?= -lkqueue
.elif $(DISTRIBUTION) == "Ubuntu"
# Default configuration for Ubuntu
LUA_INCLUDE ?= /usr/include/lua5.4
LUA_LIBDIR  ?= /usr/lib/x86_64-linux-gnu
LUA_LIBRARY ?= lua5.4
PGSQL_INCLUDE ?= /usr/include
PGSQL_LIBDIR  ?= /usr/lib/x86_64-linux-gnu
PGSQL_LIBRARY ?= pq
KQUEUE_INCLUDE_FLAGS ?= -I /usr/include/kqueue
KQUEUE_FLAGS ?= -lkqueue
.else
.warning Could not determine Linux distribution. You might need to set LUA_INCLUDE, LUA_LIBDIR, LUA_LIBRARY, KQUEUE_INCLUDE_FLAGS, and KQUEUE_FLAGS manually!
.endif

.else
.warning Could not determine Platform. You might need to set LUA_INCLUDE, LUA_LIBDIR, LUA_LIBRARY, KQUEUE_INCLUDE_FLAGS, and KQUEUE_FLAGS manually!
.endif

# Default configuration
LUA_INCLUDE ?= /usr/include
LUA_LIBDIR  ?= /usr/lib
LUA_LIBRARY ?= lua
PGSQL_INCLUDE ?= /usr/include
PGSQL_LIBDIR  ?= /usr/lib
PGSQL_LIBRARY ?= pq
KQUEUE_FLAGS ?= -lkqueue
LUA_CMD ?= lua

.export LUA_CMD

all:: target/lua-libs target/c-libs/neumond/lkq.so target/c-libs/neumond/nbio.so target/c-libs/neumond/pgeff.so

target/lua-libs: src/*.lua
	mkdir -p target/lua-libs/neumond
	mkdir -p target/lua-libs/neumond/wait/posix
	cp src/effect.lua target/lua-libs/neumond/
	cp src/yield.lua target/lua-libs/neumond/
	cp src/fiber.lua target/lua-libs/neumond/
	cp src/wait.lua target/lua-libs/neumond/
	cp src/wait_posix.lua target/lua-libs/neumond/wait/posix.lua
	cp src/wait_posix_blocking.lua target/lua-libs/neumond/wait/posix/blocking.lua
	cp src/wait_posix_fiber.lua target/lua-libs/neumond/wait/posix/fiber.lua
	cp src/eio.lua target/lua-libs/neumond/
	cp src/subprocess.lua target/lua-libs/neumond/
	cp src/web.lua target/lua-libs/neumond/
	cp src/scgi.lua target/lua-libs/neumond/
	touch target/lua-libs

target/c-libs/neumond/lkq.so: target/obj/lkq.o
	mkdir -p target/c-libs/neumond
	cc -shared -o target/c-libs/neumond/lkq.so target/obj/lkq.o $(KQUEUE_FLAGS)

target/obj/lkq.o: src/lkq.c
	mkdir -p target/obj
	cc -c -Wall -g -fPIC -o target/obj/lkq.o -I $(LUA_INCLUDE) $(KQUEUE_INCLUDE_FLAGS) src/lkq.c

target/c-libs/neumond/nbio.so: target/obj/nbio.o
	mkdir -p target/c-libs/neumond
	cc -shared -o target/c-libs/neumond/nbio.so target/obj/nbio.o

target/obj/nbio.o: src/nbio.c
	mkdir -p target/obj
	cc -c -Wall -g -fPIC -o target/obj/nbio.o -I $(LUA_INCLUDE) src/nbio.c

target/c-libs/neumond/pgeff.so: target/obj/pgeff.o
	mkdir -p target/c-libs/neumond
	cc -shared -o target/c-libs/neumond/pgeff.so target/obj/pgeff.o -L $(PGSQL_LIBDIR) -l $(PGSQL_LIBRARY)

target/obj/pgeff.o: src/pgeff.c
	mkdir -p target/obj
	cc -c -Wall -g -fPIC -o target/obj/pgeff.o -I $(LUA_INCLUDE) -I $(PGSQL_INCLUDE) src/pgeff.c

test:: all
	cd testing && ./run-tests.sh

clean::
	rm -Rf target/
