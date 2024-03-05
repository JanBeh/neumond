# BSD Makefile
# On GNU systems, use bmake.

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
# Default configuration for other Linux distributions
.warning Could not determine Linux distribution. You might need to set LUA_INCLUDE, LUA_LIBDIR, LUA_LIBRARY, KQUEUE_INCLUDE_FLAGS, and KQUEUE_FLAGS manually!
LUA_INCLUDE ?= /usr/include
LUA_LIBDIR  ?= /usr/lib
LUA_LIBRARY ?= lua
PGSQL_INCLUDE ?= /usr/include
PGSQL_LIBDIR  ?= /usr/lib
PGSQL_LIBRARY ?= pq
KQUEUE_FLAGS ?= -lkqueue
.endif

.else
# Default configuration for other systems
.warning Could not determine Platform. You might need to set LUA_INCLUDE, LUA_LIBDIR, LUA_LIBRARY, KQUEUE_INCLUDE_FLAGS, and KQUEUE_FLAGS manually!
LUA_INCLUDE ?= /usr/include
LUA_LIBDIR  ?= /usr/lib
LUA_LIBRARY ?= lua
PGSQL_INCLUDE ?= /usr/include
PGSQL_LIBDIR  ?= /usr/lib
PGSQL_LIBRARY ?= pq
KQUEUE_FLAGS ?= -lkqueue
.endif

all:: lkq.so nbio.so pgeff.so

lkq.so: lkq.o
	cc -shared -o lkq.so lkq.o $(KQUEUE_FLAGS)

lkq.o: lkq.c
	cc -c -Wall -g -fPIC -o lkq.o -I $(LUA_INCLUDE) $(KQUEUE_INCLUDE_FLAGS) lkq.c

nbio.so: nbio.o
	cc -shared -o nbio.so nbio.o

nbio.o: nbio.c
	cc -c -Wall -g -fPIC -o nbio.o -I $(LUA_INCLUDE) nbio.c

pgeff.so: pgeff.o
	cc -shared -o pgeff.so pgeff.o -L $(PGSQL_LIBDIR) -l $(PGSQL_LIBRARY)

pgeff.o: pgeff.c
	cc -c -Wall -g -fPIC -o pgeff.o -I $(LUA_INCLUDE) -I $(PGSQL_INCLUDE) pgeff.c

clean::
	rm -f lkq.o lkq.so nbio.o nbio.so pgeff.o pgeff.so
