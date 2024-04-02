#ifdef __linux__
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#else
#ifdef _GNU_SOURCE
#error Defining _GNU_SOURCE may result in non-compliant strerror_r definition and is supported for GNU/Linux only.
#endif
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif
#endif

#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <signal.h>

// On platforms without SO_NOSIGPIPE, SIGPIPE needs to be ignored process-wide:
#ifndef SO_NOSIGPIPE
#define NBIO_IGNORE_SIGPIPE_COMPLETELY
#endif

#include <lua.h>
#include <lauxlib.h>

// Preferred chunk size:
#define NBIO_CHUNKSIZE 8192

// Backlog for incoming connections:
#define NBIO_LISTEN_BACKLOG 256

// Default flags when opening files:
#define NBIO_OPEN_DEFAULT_FLAGS "r"

// Maximum length of path for local sockets:
#define NBIO_SUN_PATH_MAXLEN \
  (sizeof(struct sockaddr_un) - offsetof(struct sockaddr_un, sun_path) - 1)

#define NBIO_MAXSTRERRORLEN 1024
#define NBIO_STRERROR_R_MSG "error detail unavailable due to noncompliant strerror_r() implementation"
#ifdef _GNU_SOURCE
#define nbio_prepare_errmsg(errcode) \
  char errmsg_buf[NBIO_MAXSTRERRORLEN] = NBIO_STRERROR_R_MSG; \
  char *errmsg = strerror_r((errcode), errmsg_buf, NBIO_MAXSTRERRORLEN)
#else
#define nbio_prepare_errmsg(errcode) \
  char errmsg[NBIO_MAXSTRERRORLEN] = NBIO_STRERROR_R_MSG; \
  strerror_r((errcode), errmsg, NBIO_MAXSTRERRORLEN)
#endif

// Lua registry keys for I/O handles, listener handles, and child handles:
#define NBIO_HANDLE_MT_REGKEY "nbio_handle"
#define NBIO_LISTENER_MT_REGKEY "nbio_listener"
#define NBIO_CHILD_MT_REGKEY "nbio_child"

// Upvalue indices used by metamethods to access method tables:
#define NBIO_HANDLE_METHODS_UPIDX 1
#define NBIO_LISTENER_METHODS_UPIDX 1
#define NBIO_CHILD_METHODS_UPIDX 1

// States of an I/O handle (SHUTDOWN means only sending part is closed):
#define NBIO_STATE_OPEN 0
#define NBIO_STATE_SHUTDOWN 1
#define NBIO_STATE_CLOSED 2

// I/O handle:
typedef struct {
  int state; // see NBIO_STATE_ constants
  int fd; // file descriptor, set to -1 when (internally) closed
  sa_family_t addrfam; // address family or AF_UNSPEC (for files)
  int shared; // non-zero for stdio descriptors that should not be messed with
  void *readbuf; // allocated read buffer (or NULL if not allocated)
  size_t readbuf_capacity; // number of bytes allocated for read buffer
  size_t readbuf_written; // number of bytes written to read buffer
  size_t readbuf_read; // number of bytes read from read buffer
  int readbuf_checked_terminator; // -1 or uchar of terminator not in readbuf
  void *writebuf; // allocated write buffer (or NULL if not allocated)
  size_t writebuf_written; // number of bytes written to write buffer
  size_t writebuf_read; // number of bytes read from write buffer
  int nopush; // state of TCP_NOPUSH or TCP_CORK: 0=off, 1=on, -1=unknown
} nbio_handle_t;

// Listener handle:
typedef struct {
  int fd; // file descriptor, set to -1 when closed
  sa_family_t addrfam; // address family (AF_LOCAL, AF_INET, AF_INET6)
} nbio_listener_t;

// Child process handle:
typedef struct {
  pid_t pid; // process ID or -1 when child status has been fetched
  int status; // waitpid status, valid when pid is set to -1
} nbio_child_t;

// Control flushing for TCP connections via TCP_NOPUSH or TCP_CORK:
static void nbio_handle_set_nopush(
  lua_State *L, nbio_handle_t *handle, int nopush
) {
  // TODO: avoid error prefix when used during writing/flushing
#if defined(TCP_NOPUSH) || defined(TCP_CORK)
  if (
    handle->nopush == nopush || handle->shared ||
    !(handle->addrfam == AF_INET6 || handle->addrfam == AF_INET)
  ) return;
#if defined(TCP_NOPUSH)
  if (
    setsockopt(handle->fd, IPPROTO_TCP, TCP_NOPUSH, &nopush, sizeof(nopush))
  ) {
    nbio_prepare_errmsg(errno);
    luaL_error(L,
      "setsockopt TCP_NOPUSH=%d failed: %s", nopush, errmsg
    );
  }
#elif defined(TCP_CORK)
  if (
    setsockopt(handle->fd, IPPROTO_TCP, TCP_CORK, &nopush, sizeof(nopush))
  ) {
    nbio_prepare_errmsg(errno);
    luaL_error(L,
      "setsockopt TCP_CORK=%d failed: %s", nopush, errmsg
    );
  }
#endif
#else
#warning Neither TCP_NOPUSH nor TCP_CORK is available.
#endif
}

// Lua function allocating memory for an I/O handle
// (as separate function to allow catching out-of-memory errors):
static int nbio_create_handle_udata(lua_State *L) {
  lua_newuserdatauv(L, sizeof(nbio_handle_t), 0);
  return 1;
}

// Convert file descriptor to I/O handle:
// When `shared` is non-zero, file descriptor will neither be closed on cleanup
// nor have socket options changed.
// When `throw` is non-zero, errors will be thrown as Lua error; otherwise
// errors are returned by pushing nil and an error message and returning 2.
static int nbio_push_handle(
  lua_State *L, int fd, sa_family_t addrfam, int shared, int throw
) {
#ifndef NBIO_IGNORE_SIGPIPE_COMPLETELY
  if (!shared) {
    static const int val = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &val, sizeof(val))) {
      nbio_prepare_errmsg(errno);
      close(fd);
      if (throw) return luaL_error(L,
        "cannot set SO_NOSIGPIPE socket option: %s", errmsg
      ); else {
        lua_pushnil(L);
        lua_pushfstring(L,
          "cannot set SO_NOSIGPIPE socket option: %s", errmsg
        );
        return 2;
      }
    }
  }
#endif
  if (throw) {
    lua_pushcfunction(L, nbio_create_handle_udata);
    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
      if (!shared) close(fd);
      return lua_error(L);
    }
  } else {
    lua_pushcfunction(L, nbio_create_handle_udata);
    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
      if (!shared) close(fd);
      lua_pushnil(L);
      lua_insert(L, -2);
      return 2;
    }
  }
  nbio_handle_t *handle = lua_touserdata(L, -1);
  handle->state = NBIO_STATE_OPEN;
  handle->fd = fd;
  handle->addrfam = addrfam;
  handle->shared = shared;
  handle->readbuf = NULL;
  handle->readbuf_capacity = 0;
  handle->readbuf_written = 0;
  handle->readbuf_read = 0;
  handle->readbuf_checked_terminator = -1;
  handle->writebuf = NULL;
  handle->writebuf_written = 0;
  handle->writebuf_read = 0;
  handle->nopush = -1;
  luaL_setmetatable(L, NBIO_HANDLE_MT_REGKEY);
  return 1;
}

// Close I/O handle (may be invoked multiple times):
static int nbio_handle_close(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  handle->state = NBIO_STATE_CLOSED;
  if (handle->fd != -1 && !handle->shared) close(handle->fd);
  handle->fd = -1;
  free(handle->readbuf);
  handle->readbuf = NULL;
  free(handle->writebuf);
  handle->writebuf = NULL;
  return 0;
}

// Shutdown sending part of handle, possibly discarding unflushed data
// (may be invoked multiple times or after close):
static int nbio_handle_shutdown(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  if (handle->state == NBIO_STATE_OPEN) {
    handle->state = NBIO_STATE_SHUTDOWN;
    if (handle->addrfam == AF_INET6 || handle->addrfam == AF_INET) {
      if (shutdown(handle->fd, SHUT_WR)) {
        nbio_prepare_errmsg(errno);
        lua_pushnil(L);
        lua_pushstring(L, errmsg);
        return 2;
      }
    } else {
      if (close(handle->fd)) {
        handle->fd = -1;
        nbio_prepare_errmsg(errno);
        lua_pushnil(L);
        lua_pushstring(L, errmsg);
        return 2;
      }
      handle->fd = -1;
    }
    free(handle->writebuf);
    handle->writebuf = NULL;
    handle->writebuf_written = 0;
    handle->writebuf_read = 0;
  }
  lua_pushboolean(L, 1);
  return 1;
}

// Close listener handle (may be invoked multiple times):
static int nbio_listener_close(lua_State *L) {
  nbio_listener_t *listener = luaL_checkudata(L, 1, NBIO_LISTENER_MT_REGKEY);
  if (listener->fd != -1) close(listener->fd);
  listener->fd = -1;
  return 0;
}

// Helper function for parsing flags to "open" function:
static int nbio_cmp_flag(const char *s, size_t len, const char *f) {
  for (size_t i=0; i<len; i++) {
    if (s[i] != f[i] || !f[i]) return -1;
  }
  if (f[len]) return -1;
  return 0;
}

// Open file and return I/O handle:
static int nbio_open(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  const char *flagsstr = luaL_optstring(L, 2, NBIO_OPEN_DEFAULT_FLAGS);
  if (!flagsstr[0]) flagsstr = NBIO_OPEN_DEFAULT_FLAGS;
  size_t flagslen = strlen(flagsstr);
  int flags = O_NONBLOCK | O_CLOEXEC;
  {
    size_t i = 0;
    for (size_t j=0; j<=flagslen; j++) {
      if (flagsstr[j] == 0 || flagsstr[j] == ',') {
        const char *s = flagsstr + i;
        size_t k = j - i;
        if (!nbio_cmp_flag(s, k, "r")) flags |= O_RDONLY;
        else if (!nbio_cmp_flag(s, k, "w")) flags |= O_WRONLY;
        else if (!nbio_cmp_flag(s, k, "rw")) flags |= O_RDWR;
        else if (!nbio_cmp_flag(s, k, "append")) flags |= O_APPEND;
        else if (!nbio_cmp_flag(s, k, "create")) flags |= O_CREAT;
        else if (!nbio_cmp_flag(s, k, "truncate")) flags |= O_TRUNC;
        else if (!nbio_cmp_flag(s, k, "exclusive")) flags |= O_EXCL;
#if defined(O_SHLOCK)
        else if (!nbio_cmp_flag(s, k, "sharedlock")) flags |= O_SHLOCK;
#endif
#if defined(O_EXLOCK)
        else if (!nbio_cmp_flag(s, k, "exclusivelock")) flags |= O_EXLOCK;
#endif
        else return luaL_argerror(L, 2, "unknown flag");
        i = j + 1;
      }
    }
  }
  int fd;
  if (flags & O_CREAT) fd = open(path, flags, (mode_t)0666);
  else fd = open(path, flags);
  if (fd == -1) {
    nbio_prepare_errmsg(errno);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  return nbio_push_handle(L, fd, AF_UNSPEC, 0, 1);
}

// Connect to local socket and return I/O handle:
static int nbio_localconnect(lua_State *L) {
  const char *path;
  path = luaL_checkstring(L, 1);
  if (strlen(path) > NBIO_SUN_PATH_MAXLEN) {
    return luaL_error(L,
      "path too long; only %d characters allowed",
      NBIO_SUN_PATH_MAXLEN
    );
  }
  struct sockaddr_un sockaddr = { .sun_family = AF_LOCAL };
  strcpy(sockaddr.sun_path, path);
  int fd = socket(PF_LOCAL, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
  if (fd == -1) {
    nbio_prepare_errmsg(errno);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  if (
    connect(fd, (struct sockaddr *)&sockaddr, sizeof(sockaddr)) &&
    errno != EINPROGRESS && errno != EINTR
  ) {
    nbio_prepare_errmsg(errno);
    close(fd);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  return nbio_push_handle(L, fd, AF_LOCAL, 0, 1);
}

// Initiate TCP connection and return I/O handle (may block on DNS resolving):
static int nbio_tcpconnect(lua_State *L) {
  const char *host, *port;
  host = luaL_checkstring(L, 1);
  port = luaL_checkstring(L, 2);
  struct addrinfo hints = { 0, };
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;
  hints.ai_flags = AI_ADDRCONFIG;
  struct addrinfo *res;
  int errcode = getaddrinfo(host, port, &hints, &res);
  if (errcode) {
    if (errcode == EAI_SYSTEM) {
      nbio_prepare_errmsg(errno);
      lua_pushnil(L);
      lua_pushfstring(L, "%s: %s", gai_strerror(errcode), errmsg);
    } else {
      lua_pushnil(L);
      lua_pushstring(L, gai_strerror(errcode));
    }
    return 2;
  }
  struct addrinfo *addrinfo;
  for (addrinfo=res; addrinfo; addrinfo=addrinfo->ai_next) {
    if (addrinfo->ai_family == AF_INET6) goto nbio_tcpconnect_found;
  }
  for (addrinfo=res; addrinfo; addrinfo=addrinfo->ai_next) {
    if (addrinfo->ai_family == AF_INET) goto nbio_tcpconnect_found;
  }
  addrinfo = res;
  nbio_tcpconnect_found:;
  int fd = socket(
    addrinfo->ai_family,  // incorrect to not use PF_* but AF_* constants here
    addrinfo->ai_socktype | SOCK_CLOEXEC | SOCK_NONBLOCK,
    addrinfo->ai_protocol
  );
  if (fd == -1) {
    nbio_prepare_errmsg(errno);
    freeaddrinfo(res);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  int addrfam = addrinfo->ai_family;
  if (connect(fd, addrinfo->ai_addr, addrinfo->ai_addrlen)) {
    freeaddrinfo(res);
    if (errno != EINPROGRESS && errno != EINTR) {
      nbio_prepare_errmsg(errno);
      close(fd);
      lua_pushnil(L);
      lua_pushstring(L, errmsg);
      return 2;
    }
  } else {
    freeaddrinfo(res);
  }
  return nbio_push_handle(L, fd, addrfam, 0, 1);
}

// Listen on local socket and return listener handle:
static int nbio_locallisten(lua_State *L) {
  const char *path;
  path = luaL_checkstring(L, 1);
  if (strlen(path) > NBIO_SUN_PATH_MAXLEN) {
    return luaL_error(L,
      "path too long; only %d characters allowed",
      NBIO_SUN_PATH_MAXLEN
    );
  }
  struct stat sb;
  if (lstat(path, &sb) == 0) {
    if (S_ISSOCK(sb.st_mode)) unlink(path);
  }
  struct sockaddr_un sockaddr = { .sun_family = AF_LOCAL };
  strcpy(sockaddr.sun_path, path);
  int fd = socket(PF_LOCAL, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd == -1) {
    nbio_prepare_errmsg(errno);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  if (bind(fd, (struct sockaddr *)&sockaddr, sizeof(sockaddr))) {
    nbio_prepare_errmsg(errno);
    close(fd);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  if (chmod(path, 0666)) {
    nbio_prepare_errmsg(errno);
    close(fd);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  if (listen(fd, NBIO_LISTEN_BACKLOG)) {
    nbio_prepare_errmsg(errno);
    close(fd);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  nbio_listener_t *listener = lua_newuserdatauv(L, sizeof(*listener), 0);
  listener->fd = fd;
  listener->addrfam = AF_LOCAL;
  luaL_setmetatable(L, NBIO_LISTENER_MT_REGKEY);
  return 1;
}

// Listen on TCP port and return listener handle:
static int nbio_tcplisten(lua_State *L) {
  const char *host, *port;
  host = luaL_optstring(L, 1, NULL);
  port = luaL_checkstring(L, 2);
  struct addrinfo hints = { 0, };
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;
  hints.ai_flags = AI_ADDRCONFIG | AI_PASSIVE;
  struct addrinfo *res;
  int errcode = getaddrinfo(host, port, &hints, &res);
  if (errcode) {
    if (errcode == EAI_SYSTEM) {
      nbio_prepare_errmsg(errno);
      lua_pushnil(L);
      lua_pushfstring(L, "%s: %s", gai_strerror(errcode), errmsg);
    } else {
      lua_pushnil(L);
      lua_pushstring(L, gai_strerror(errcode));
    }
    return 2;
  }
  struct addrinfo *addrinfo;
  for (addrinfo=res; addrinfo; addrinfo=addrinfo->ai_next) {
    if (addrinfo->ai_family == AF_INET6) goto nbio_tcpconnect_found;
  }
  for (addrinfo=res; addrinfo; addrinfo=addrinfo->ai_next) {
    if (addrinfo->ai_family == AF_INET) goto nbio_tcpconnect_found;
  }
  addrinfo = res;
  nbio_tcpconnect_found:;
  int fd = socket(
    addrinfo->ai_family,  // incorrect to not use PF_* but AF_* constants here
    addrinfo->ai_socktype | SOCK_CLOEXEC | SOCK_NONBLOCK,
    addrinfo->ai_protocol
  );
  if (fd == -1) {
    nbio_prepare_errmsg(errno);
    freeaddrinfo(res);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  {
    static const int val = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &val, sizeof(val))) {
      nbio_prepare_errmsg(errno);
      freeaddrinfo(res);
      close(fd);
      lua_pushnil(L);
      lua_pushfstring(L, "cannot set SO_REUSEADDR socket option: %s", errmsg);
      return 2;
    }
  }
  if (addrinfo->ai_family == AF_INET6) {
    const int val = (host != NULL) ? 1 : 0;
    if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &val, sizeof(val))) {
      nbio_prepare_errmsg(errno);
      freeaddrinfo(res);
      close(fd);
      lua_pushnil(L);
      lua_pushfstring(L, "cannot set IPV6_V6ONLY socket option: %s", errmsg);
      return 2;
    }
  }
  if (bind(fd, addrinfo->ai_addr, addrinfo->ai_addrlen)) {
    nbio_prepare_errmsg(errno);
    freeaddrinfo(res);
    close(fd);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  int addrfam = addrinfo->ai_family;
  freeaddrinfo(res);
  if (listen(fd, NBIO_LISTEN_BACKLOG)) {
    nbio_prepare_errmsg(errno);
    close(fd);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  nbio_listener_t *listener = lua_newuserdatauv(L, sizeof(*listener), 0);
  listener->fd = fd;
  listener->addrfam = addrfam;
  luaL_setmetatable(L, NBIO_LISTENER_MT_REGKEY);
  return 1;
}

// __index metamethod for I/O handle:
static int nbio_handle_index(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  const char *key = lua_tostring(L, 2);
  if (key) {
    if (!strcmp(key, "fd")) {
      if (handle->fd == -1) lua_pushboolean(L, 0);
      else lua_pushinteger(L, handle->fd);
      return 1;
    }
  }
  lua_settop(L, 2);
  lua_gettable(L, lua_upvalueindex(NBIO_HANDLE_METHODS_UPIDX));
  return 1;
}

// __index metamethod for listener handle:
static int nbio_listener_index(lua_State *L) {
  nbio_listener_t *listener = luaL_checkudata(L, 1, NBIO_LISTENER_MT_REGKEY);
  const char *key = lua_tostring(L, 2);
  if (key) {
    if (!strcmp(key, "fd")) {
      if (listener->fd == -1) lua_pushboolean(L, 0);
      else lua_pushinteger(L, listener->fd);
      return 1;
    }
  }
  lua_settop(L, 2);
  lua_gettable(L, lua_upvalueindex(NBIO_LISTENER_METHODS_UPIDX));
  return 1;
}

// __index metamethod for child process handle:
static int nbio_child_index(lua_State *L) {
  nbio_child_t *child = luaL_checkudata(L, 1, NBIO_CHILD_MT_REGKEY);
  const char *key = lua_tostring(L, 2);
  if (key) {
    if (!strcmp(key, "pid")) {
      if (child->pid) lua_pushinteger(L, child->pid);
      else lua_pushboolean(L, 0);
      return 1;
    }
    if (!strcmp(key, "stdin")) {
      lua_getiuservalue(L, 1, 1);
      return 1;
    }
    if (!strcmp(key, "stdout")) {
      lua_getiuservalue(L, 1, 2);
      return 1;
    }
    if (!strcmp(key, "stderr")) {
      lua_getiuservalue(L, 1, 3);
      return 1;
    }
  }
  lua_settop(L, 2);
  lua_gettable(L, lua_upvalueindex(NBIO_CHILD_METHODS_UPIDX));
  return 1;
}

// Unbuffered reads from I/O handle:
static int nbio_handle_read_unbuffered(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  lua_Integer maxlen = luaL_optinteger(L, 2, NBIO_CHUNKSIZE);
  if (maxlen <= 0) {
    return luaL_argerror(L, 2, "maximum byte count must be positive");
  }
  if (handle->state == NBIO_STATE_CLOSED) {
    return luaL_error(L, "read from closed handle");
  }
  if (handle->readbuf_written > 0) {
    void *start = handle->readbuf + handle->readbuf_read;
    size_t available = handle->readbuf_written - handle->readbuf_read;
    if (maxlen < available) {
      lua_pushlstring(L, start, maxlen);
      handle->readbuf_read += maxlen;
    } else {
      lua_pushlstring(L, start, available);
      handle->readbuf_written = 0;
      handle->readbuf_read = 0;
    }
    return 1;
  }
  if (handle->fd == -1) {
    // simulate EOF
    lua_pushboolean(L, 0);
    lua_pushliteral(L, "end of data");
    return 2;
  }
  if (maxlen > handle->readbuf_capacity) {
    void *newbuf = realloc(handle->readbuf, maxlen);
    if (!newbuf) return luaL_error(L, "buffer allocation failed");
    handle->readbuf = newbuf;
    handle->readbuf_capacity = maxlen;
  }
  ssize_t result = read(handle->fd, handle->readbuf, maxlen);
  if (result > 0) {
    lua_pushlstring(L, handle->readbuf, result);
    return 1;
  } else if (result == 0) {
    lua_pushboolean(L, 0);
    lua_pushliteral(L, "end of data");
    return 2;
  } else if (errno == EAGAIN || errno == EINTR) {
    lua_pushlstring(L, NULL, 0);
    return 1;
  } else {
    nbio_prepare_errmsg(errno);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
}

// Buffered reads from I/O handle:
static int nbio_handle_read(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  lua_Integer maxlen = luaL_optinteger(L, 2, NBIO_CHUNKSIZE);
  size_t terminator_len;
  const char *terminator = lua_tolstring(L, 3, &terminator_len);
  if (maxlen <= 0) {
    return luaL_argerror(L, 2, "maximum byte count must be positive");
  }
  if (handle->state == NBIO_STATE_CLOSED) {
    return luaL_error(L, "read from closed handle");
  }
  if (terminator != NULL && terminator_len != 1) {
    return luaL_argerror(L, 3, "optional terminator must be a single char");
  }
  if (handle->readbuf_written > 0) {
    void *start = handle->readbuf + handle->readbuf_read;
    size_t available = handle->readbuf_written - handle->readbuf_read;
    size_t uselen = maxlen;
    if (terminator != NULL) {
      if ((unsigned char)*terminator != handle->readbuf_checked_terminator) {
        handle->readbuf_checked_terminator = (unsigned char)*terminator;
        for (size_t i=0; i<available; i++) {
          if (((char *)start)[i] == *terminator) {
            uselen = i + 1;
            handle->readbuf_checked_terminator = -1;
            break;
          }
        }
      }
    }
    if (available < uselen) {
      if (handle->readbuf_read > 0) {
        memmove(handle->readbuf, start, available);
        handle->readbuf_written = available;
        handle->readbuf_read = 0;
      }
    } else {
      lua_pushlstring(L, start, uselen);
      if (uselen == available) {
        handle->readbuf_written = 0;
        handle->readbuf_read = 0;
      } else {
        handle->readbuf_read += uselen;
      }
      return 1;
    }
  }
  // handle->readbuf_read is zero at this point
  if (handle->fd == -1) {
    // simulate EOF
    lua_pushboolean(L, 0);
    lua_pushliteral(L, "end of data");
    return 2;
  }
  while (1) {
    if (handle->readbuf_written > SIZE_MAX - NBIO_CHUNKSIZE) {
      return luaL_error(L, "buffer allocation failed");
    }
    size_t needed_capacity = handle->readbuf_written + NBIO_CHUNKSIZE;
    if (handle->readbuf_capacity < needed_capacity) {
      if (handle->readbuf_capacity > SIZE_MAX / 2) {
        return luaL_error(L, "buffer allocation failed");
      }
      size_t newcap = 2 * handle->readbuf_capacity;
      if (newcap < needed_capacity) newcap = needed_capacity;
      void *newbuf = realloc(handle->readbuf, newcap);
      if (!newbuf) return luaL_error(L, "buffer allocation failed");
      handle->readbuf = newbuf;
      handle->readbuf_capacity = newcap;
    }
    ssize_t result = read(
      handle->fd,
      handle->readbuf + handle->readbuf_written,
      NBIO_CHUNKSIZE
    );
    if (result > 0) {
      size_t old_written = handle->readbuf_written;
      handle->readbuf_written += result;
      size_t uselen = maxlen;
      if (terminator != NULL) {
        handle->readbuf_checked_terminator = (unsigned char)*terminator;
        for (size_t i=old_written; i<handle->readbuf_written; i++) {
          if (((char *)handle->readbuf)[i] == *terminator) {
            uselen = i + 1;
            handle->readbuf_checked_terminator = -1;
            break;
          }
        }
      } else {
        handle->readbuf_checked_terminator = -1;
      }
      if (handle->readbuf_written >= uselen) {
        lua_pushlstring(L, handle->readbuf, uselen);
        if (handle->readbuf_written > uselen) {
          handle->readbuf_read = uselen;
        } else {
          handle->readbuf_written = 0;
        }
        return 1;
      }
    } else if (result == 0) {
      if (handle->readbuf_written > 0) {
        lua_pushlstring(L, handle->readbuf, handle->readbuf_written);
        handle->readbuf_written = 0;
        return 1;
      }
      lua_pushboolean(L, 0);
      lua_pushliteral(L, "end of data");
      return 2;
    } else if (errno == EAGAIN || errno == EINTR) {
      lua_pushlstring(L, NULL, 0);
      return 1;
    } else {
      nbio_prepare_errmsg(errno);
      lua_pushnil(L);
      lua_pushstring(L, errmsg);
      return 2;
    }
  }
}

// Unbuffered writes to I/O handle (implicitly flushes buffered data):
static int nbio_handle_write_unbuffered(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  size_t bufsize;
  const char *buf = luaL_checklstring(L, 2, &bufsize);
  lua_Integer start = luaL_optinteger(L, 3, 1);
  if (bufsize > LUA_MAXINTEGER) {
    return luaL_error(L, "chunk length longer than LUA_MAXINTEGER");
  }
  lua_Integer end = luaL_optinteger(L, 4, (lua_Integer)bufsize);
  if (handle->state == NBIO_STATE_CLOSED) {
    return luaL_error(L, "write to closed handle");
  }
  if (handle->state == NBIO_STATE_SHUTDOWN) {
    return luaL_error(L, "write to shut down handle");
  }
  ssize_t written;
  if (handle->writebuf_written > 0) {
    written = write(
      handle->fd,
      handle->writebuf + handle->writebuf_read,
      handle->writebuf_written - handle->writebuf_read
    );
    if (written >= 0) {
      handle->writebuf_read += written;
      if (handle->writebuf_read == handle->writebuf_written) {
        handle->writebuf_written = 0;
        handle->writebuf_read = 0;
      } else {
        nbio_handle_set_nopush(L, handle, 0);
        lua_pushinteger(L, 0);
        return 1;
      }
    } else if (errno == EAGAIN || errno == EINTR) {
      nbio_handle_set_nopush(L, handle, 0);
      lua_pushinteger(L, 0);
      return 1;
    } else if (errno == EPIPE) {
      nbio_handle_set_nopush(L, handle, 0);
      lua_pushboolean(L, 0);
      lua_pushliteral(L, "peer closed stream");
      return 2;
    } else {
      nbio_prepare_errmsg(errno);
      nbio_handle_set_nopush(L, handle, 0);
      lua_pushnil(L);
      lua_pushstring(L, errmsg);
      return 2;
    }
  }
  if (start <= -(lua_Integer)bufsize) start = 1;
  else if (start < 0) start = bufsize + start + 1;
  else if (start == 0) start = 1;
  if (end < 0) end = bufsize + end + 1;
  else if (end > bufsize) end = bufsize;
  if (end < start) {
    start = 1;
    end = 0;
  }
  written = write(handle->fd, buf-1+start, end-start+1);
  if (written >= 0) {
    nbio_handle_set_nopush(L, handle, 0);
    lua_pushinteger(L, written);
    return 1;
  } else if (errno == EAGAIN || errno == EINTR) {
    nbio_handle_set_nopush(L, handle, 0);
    lua_pushinteger(L, 0);
    return 1;
  } else if (errno == EPIPE) {
    nbio_handle_set_nopush(L, handle, 0);
    lua_pushboolean(L, 0);
    lua_pushliteral(L, "peer closed stream");
    return 2;
  } else {
    nbio_prepare_errmsg(errno);
    nbio_handle_set_nopush(L, handle, 0);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
}

// Buffered writes to I/O handle:
static int nbio_handle_write(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  size_t bufsize;
  const char *buf = luaL_checklstring(L, 2, &bufsize);
  lua_Integer start = luaL_optinteger(L, 3, 1);
  if (bufsize > LUA_MAXINTEGER) {
    return luaL_error(L, "chunk length longer than LUA_MAXINTEGER");
  }
  lua_Integer end = luaL_optinteger(L, 4, (lua_Integer)bufsize);
  if (handle->state == NBIO_STATE_CLOSED) {
    return luaL_error(L, "write to closed handle");
  }
  if (handle->state == NBIO_STATE_SHUTDOWN) {
    return luaL_error(L, "write to shut down handle");
  }
  nbio_handle_set_nopush(L, handle, 1);
  if (start <= -(lua_Integer)bufsize) start = 1;
  else if (start < 0) start = bufsize + start + 1;
  else if (start == 0) start = 1;
  if (end < 0) end = bufsize + end + 1;
  else if (end > bufsize) end = bufsize;
  if (end < start) {
    start = 1;
    end = 0;
  }
  size_t to_write = end - start + 1;
  ssize_t written;
  if (
    handle->writebuf_written > 0 && (
      to_write > NBIO_CHUNKSIZE || // avoids integer overflow
      handle->writebuf_written + to_write > NBIO_CHUNKSIZE
    )
  ) {
    written = write(
      handle->fd,
      handle->writebuf + handle->writebuf_read,
      handle->writebuf_written - handle->writebuf_read
    );
    if (written >= 0) {
      handle->writebuf_read += written;
      if (handle->writebuf_read == handle->writebuf_written) {
        handle->writebuf_written = 0;
        handle->writebuf_read = 0;
      } else {
        lua_pushinteger(L, 0);
        return 1;
      }
    } else if (errno == EAGAIN || errno == EINTR) {
      lua_pushinteger(L, 0);
      return 1;
    } else if (errno == EPIPE) {
      lua_pushboolean(L, 0);
      lua_pushliteral(L, "peer closed stream");
      return 2;
    } else {
      nbio_prepare_errmsg(errno);
      lua_pushnil(L);
      lua_pushstring(L, errmsg);
      return 2;
    }
  }
  if (
    to_write <= NBIO_CHUNKSIZE && // avoids integer overflow
    handle->writebuf_written + to_write <= NBIO_CHUNKSIZE
  ) {
    if (handle->writebuf == NULL) {
      handle->writebuf = malloc(NBIO_CHUNKSIZE);
      if (!handle->writebuf) return luaL_error(L, "buffer allocation failed");
    }
    memcpy(handle->writebuf + handle->writebuf_written, buf-1+start, to_write);
    handle->writebuf_written += to_write;
    lua_pushinteger(L, to_write);
    return 1;
  }
  if (handle->writebuf_written > 0) {
    lua_pushinteger(L, 0);
    return 1;
  }
  written = write(handle->fd, buf-1+start, to_write);
  if (written >= 0) {
    lua_pushinteger(L, written);
    return 1;
  } else if (errno == EAGAIN || errno == EINTR) {
    lua_pushinteger(L, 0);
    return 1;
  } else if (errno == EPIPE) {
    lua_pushboolean(L, 0);
    lua_pushliteral(L, "peer closed stream");
    return 2;
  } else {
    nbio_prepare_errmsg(errno);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
}

// Flush write buffer of I/O handle:
static int nbio_handle_flush(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  if (handle->state == NBIO_STATE_CLOSED) {
    return luaL_error(L, "flushing closed handle");
  }
  if (handle->state == NBIO_STATE_SHUTDOWN) {
    return luaL_error(L, "flushing shut down handle");
  }
  if (handle->writebuf_written > 0) {
    ssize_t written = write(
      handle->fd,
      handle->writebuf + handle->writebuf_read,
      handle->writebuf_written - handle->writebuf_read
    );
    if (written >= 0) {
      handle->writebuf_read += written;
    } else if (errno == EAGAIN || errno == EINTR) {
      // nothing
    } else if (errno == EPIPE) {
      nbio_handle_set_nopush(L, handle, 0);
      lua_pushboolean(L, 0);
      lua_pushliteral(L, "peer closed stream");
      return 2;
    } else {
      nbio_prepare_errmsg(errno);
      nbio_handle_set_nopush(L, handle, 0);
      lua_pushnil(L);
      lua_pushstring(L, errmsg);
      return 2;
    }
  }
  nbio_handle_set_nopush(L, handle, 0);
  size_t remaining = handle->writebuf_written - handle->writebuf_read;
  if (remaining == 0) {
    handle->writebuf_written = 0;
    handle->writebuf_read = 0;
  }
  lua_pushinteger(L, remaining);
  return 1;
}

// Accept connection from listener handle:
static int nbio_listener_accept(lua_State *L) {
  nbio_listener_t *listener = luaL_checkudata(L, 1, NBIO_LISTENER_MT_REGKEY);
  if (listener->fd == -1) return luaL_error(L,
    "attempt to use closed listener"
  );
  int fd;
  while (1) {
    fd = accept4(listener->fd, NULL, NULL, SOCK_CLOEXEC);
    if (fd == -1) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        lua_pushboolean(L, 0);
        lua_pushliteral(L, "no incoming connection pending");
        return 2;
      } else if (errno != EINTR) {
        nbio_prepare_errmsg(errno);
        lua_pushnil(L);
        lua_pushstring(L, errmsg);
        return 2;
      }
    } else {
      int flags = fcntl(fd, F_GETFL, 0);
      if (flags == -1) {
        nbio_prepare_errmsg(errno);
        close(fd);
        return luaL_error(L, "error in fcntl call: %s", errmsg);
      }
      flags |= O_NONBLOCK;
      if (fcntl(fd, F_SETFL, flags) == -1) {
        nbio_prepare_errmsg(errno);
        close(fd);
        return luaL_error(L, "error in fcntl call: %s", errmsg);
      }
      return nbio_push_handle(L, fd, listener->addrfam, 0, 1);
    }
  }
}

// Close child process handle and kill and reap child process if still running
// (may be invoked multiple times):
static int nbio_child_close(lua_State *L) {
  nbio_child_t *child = luaL_checkudata(L, 1, NBIO_CHILD_MT_REGKEY);
  lua_getiuservalue(L, 1, 1);
  lua_toclose(L, -1);
  lua_getiuservalue(L, 1, 2);
  lua_toclose(L, -1);
  lua_getiuservalue(L, 1, 3);
  lua_toclose(L, -1);
  if (child->pid) {
    int status;
    if (kill(child->pid, SIGKILL)) {
      nbio_prepare_errmsg(errno);
      return luaL_error(L,
        "error in kill call when closing child handle: %s", errmsg
      );
    }
    while (waitpid(child->pid, &status, 0) == -1) {
      if (errno != EINTR) {
        nbio_prepare_errmsg(errno);
        return luaL_error(L,
          "error in waitpid call when closing child handle: %s", errmsg
        );
      }
    }
    child->pid = 0;
    child->status = status;
  }
  return 0;
}

// Send signal to child process (no-op if child has terminated):
static int nbio_child_kill(lua_State *L) {
  nbio_child_t *child = luaL_checkudata(L, 1, NBIO_CHILD_MT_REGKEY);
  int sig = luaL_optinteger(L, 2, SIGKILL);
  if (child->pid) {
    if (kill(child->pid, sig)) {
      nbio_prepare_errmsg(errno);
      return luaL_error(L, "error in kill call: %s", errmsg);
    }
  }
  lua_settop(L, 1);
  return 1;
}

// Check if child is still running and obtain status if terminated
// (may be invoked multiple times):
static int nbio_child_wait(lua_State *L) {
  nbio_child_t *child = luaL_checkudata(L, 1, NBIO_CHILD_MT_REGKEY);
  if (child->pid) {
    pid_t waitedpid;
    int status;
    while ((waitedpid = waitpid(child->pid, &status, WNOHANG)) == -1) {
      if (errno != EINTR) {
        nbio_prepare_errmsg(errno);
        return luaL_error(L, "error in waitpid call: %s", errmsg);
      }
    }
    if (!waitedpid) {
      lua_pushboolean(L, 0);
      lua_pushliteral(L, "process is still running");
      return 2;
    }
    child->pid = 0;
    child->status = status;
  }
  if (WIFEXITED(child->status)) {
    lua_pushinteger(L, WEXITSTATUS(child->status));
  } else if (WIFSIGNALED(child->status)) {
    lua_pushinteger(L, -WTERMSIG(child->status));
  } else {
    return luaL_error(L, "unexpected status value returned by waitpid call");
  }
  return 1;
}

// Execute child process and return child handle:
static int nbio_execute(lua_State *L) {
  int argc = lua_gettop(L);
  const char **argv = lua_newuserdatauv(L, (argc + 1) * sizeof(char *), 0);
  for (int i=0; i<argc; i++) argv[i] = luaL_checkstring(L, i+1);
  argv[argc] = NULL;
  nbio_child_t *child = lua_newuserdatauv(L, sizeof(nbio_child_t), 3);
  child->pid = 0;
  luaL_setmetatable(L, NBIO_CHILD_MT_REGKEY);
  int sockin[2], sockout[2], sockerr[2], sockipc[2];
  if (socketpair(PF_LOCAL, SOCK_STREAM | SOCK_CLOEXEC, 0, sockin)) {
    nbio_prepare_errmsg(errno);
    lua_toclose(L, -1);
    lua_pushnil(L);
    lua_pushfstring(L, "could not create socket pair for stdio: %s", errmsg);
    return 2;
  }
  if (nbio_push_handle(L, sockin[0], AF_UNSPEC, 0, 0) == 2) {
    lua_toclose(L, -3);
    close(sockin[1]);
    return 2;
  }
  lua_setiuservalue(L, -2, 1);
  if (socketpair(PF_LOCAL, SOCK_STREAM | SOCK_CLOEXEC, 0, sockout)) {
    nbio_prepare_errmsg(errno);
    lua_toclose(L, -1);
    close(sockin[1]);
    lua_pushnil(L);
    lua_pushfstring(L, "could not create socket pair for stdio: %s", errmsg);
    return 2;
  }
  if (nbio_push_handle(L, sockout[0], AF_UNSPEC, 0, 0) == 2) {
    lua_toclose(L, -3);
    close(sockin[1]);
    close(sockout[1]);
    return 2;
  }
  lua_setiuservalue(L, -2, 2);
  if (socketpair(PF_LOCAL, SOCK_STREAM | SOCK_CLOEXEC, 0, sockerr)) {
    nbio_prepare_errmsg(errno);
    lua_toclose(L, -1);
    close(sockin[1]);
    close(sockout[1]);
    lua_pushnil(L);
    lua_pushfstring(L, "could not create socket pair for stdio: %s", errmsg);
    return 2;
  }
  if (nbio_push_handle(L, sockerr[0], AF_UNSPEC, 0, 0) == 2) {
    lua_toclose(L, -3);
    close(sockin[1]);
    close(sockout[1]);
    close(sockerr[1]);
    return 2;
  }
  lua_setiuservalue(L, -2, 3);
  if (socketpair(PF_LOCAL, SOCK_STREAM | SOCK_CLOEXEC, 0, sockipc)) {
    nbio_prepare_errmsg(errno);
    lua_toclose(L, -1);
    close(sockin[1]);
    close(sockout[1]);
    close(sockerr[1]);
    lua_pushnil(L);
    lua_pushfstring(L, "could not create socket pair for IPC: %s", errmsg);
  }
  child->pid = fork();
  if (child->pid == -1) {
    nbio_prepare_errmsg(errno);
    lua_toclose(L, -1);
    close(sockin[1]);
    close(sockout[1]);
    close(sockerr[1]);
    close(sockipc[0]);
    close(sockipc[1]);
    lua_pushnil(L);
    lua_pushfstring(L, "could not fork: %s", errmsg);
    return 2;
  }
  if (!child->pid) {
    if (dup2(sockin[1], 0) == -1) goto nbio_execute_stdio_error;
    if (dup2(sockout[1], 1) == -1) goto nbio_execute_stdio_error;
    if (dup2(sockerr[1], 2) == -1) goto nbio_execute_stdio_error;
    if (dup2(sockipc[1], 3) == -1) goto nbio_execute_stdio_error;
    closefrom(4);
    if (fcntl(0, F_SETFD, 0) == -1) goto nbio_execute_stdio_error;
    if (fcntl(1, F_SETFD, 0) == -1) goto nbio_execute_stdio_error;
    if (fcntl(2, F_SETFD, 0) == -1) goto nbio_execute_stdio_error;
    execvp(argv[0], (char *const *)argv);
    char ipcmsg[1 + sizeof(int)];
    int err = errno;
    ipcmsg[0] = 'A';
    memcpy(ipcmsg + 1, &err, sizeof(err));
    send(3, ipcmsg, 1 + sizeof(int), 0);
    _exit(1);
    nbio_execute_stdio_error:
    err = errno;
    ipcmsg[0] = 'B';
    memcpy(ipcmsg + 1, &err, sizeof(err));
    send(3, ipcmsg, 1 + sizeof(int), 0);
    _exit(1);
  }
  close(sockin[1]);
  close(sockout[1]);
  close(sockerr[1]);
  close(sockipc[1]);
  while (1) {
    char ipcmsg[1 + sizeof(int)];
    ssize_t bytes = recv(sockipc[0], ipcmsg, 1 + sizeof(int), 0);
    if (bytes == -1) {
      if (errno != EINTR) {
        nbio_prepare_errmsg(errno);
        lua_toclose(L, -1);
        lua_pushnil(L);
        lua_pushfstring(L, "error during IPC with fork: %s", errmsg);
        return 2;
      }
    } else if (bytes == 0) {
      return 1;
    } else if (bytes == 1 + sizeof(int)) {
      char msgtype = ipcmsg[0];
      int err;
      memcpy(&err, ipcmsg + 1, sizeof(err));
      if (msgtype == 'A') {
        nbio_prepare_errmsg(err);
        lua_toclose(L, -1);
        lua_pushnil(L);
        lua_pushfstring(L, "could not execute: %s", errmsg);
        return 2;
      } else if (msgtype == 'B') {
        nbio_prepare_errmsg(err);
        lua_toclose(L, -1);
        lua_pushnil(L);
        lua_pushfstring(L, "could not prepare stdio in fork: %s", errmsg);
        return 2;
      } else {
        lua_toclose(L, -1);
        lua_pushnil(L);
        lua_pushfstring(L, "error during IPC with fork: unknown message type");
        return 2;
      }
    } else {
      lua_toclose(L, -1);
      lua_pushnil(L);
      lua_pushfstring(L, "error during IPC with fork: wrong message length");
      return 2;
    }
  }
  return 1;
}

// Module functions:
static const struct luaL_Reg nbio_module_funcs[] = {
  {"open", nbio_open},
  {"localconnect", nbio_localconnect},
  {"tcpconnect", nbio_tcpconnect},
  {"locallisten", nbio_locallisten},
  {"tcplisten", nbio_tcplisten},
  {"execute", nbio_execute},
  {NULL, NULL}
};

// I/O handle methods:
static const struct luaL_Reg nbio_handle_methods[] = {
  {"close", nbio_handle_close},
  {"shutdown", nbio_handle_shutdown},
  {"read_unbuffered", nbio_handle_read_unbuffered},
  {"read", nbio_handle_read},
  {"write_unbuffered", nbio_handle_write_unbuffered},
  {"write", nbio_handle_write},
  {"flush", nbio_handle_flush},
  {NULL, NULL}
};

// Listener handle methods:
static const struct luaL_Reg nbio_listener_methods[] = {
  {"close", nbio_listener_close},
  {"accept", nbio_listener_accept},
  {NULL, NULL}
};

// Child process handle methods:
static const struct luaL_Reg nbio_child_methods[] = {
  {"close", nbio_child_close},
  {"kill", nbio_child_kill},
  {"wait", nbio_child_wait},
  {NULL, NULL}
};

// I/O handle metamethods:
static const struct luaL_Reg nbio_handle_metamethods[] = {
  {"__close", nbio_handle_close},
  {"__gc", nbio_handle_close},
  {"__index", nbio_handle_index},
  {NULL, NULL}
};

// Listener handle metamethods:
static const struct luaL_Reg nbio_listener_metamethods[] = {
  {"__close", nbio_listener_close},
  {"__gc", nbio_listener_close},
  {"__index", nbio_listener_index},
  {NULL, NULL}
};

// Child process handle metamethods:
static const struct luaL_Reg nbio_child_metamethods[] = {
  {"__close", nbio_child_close},
  {"__gc", nbio_child_close},
  {"__index", nbio_child_index},
  {NULL, NULL}
};

// Library initialization:
int luaopen_nbio(lua_State *L) {
  luaL_newmetatable(L, NBIO_HANDLE_MT_REGKEY);
  lua_newtable(L);
  luaL_setfuncs(L, nbio_handle_methods, 0);
  luaL_setfuncs(L, nbio_handle_metamethods, 1);
  lua_pop(L, 1);

  luaL_newmetatable(L, NBIO_LISTENER_MT_REGKEY);
  lua_newtable(L);
  luaL_setfuncs(L, nbio_listener_methods, 0);
  luaL_setfuncs(L, nbio_listener_metamethods, 1);
  lua_pop(L, 1);

  luaL_newmetatable(L, NBIO_CHILD_MT_REGKEY);
  lua_newtable(L);
  luaL_setfuncs(L, nbio_child_methods, 0);
  luaL_setfuncs(L, nbio_child_metamethods, 1);
  lua_pop(L, 1);

  lua_newtable(L);
  luaL_setfuncs(L, nbio_module_funcs, 0);
  nbio_push_handle(L, 0, AF_UNSPEC, 1, 1);
  lua_setfield(L, -2, "stdin");
  nbio_push_handle(L, 1, AF_UNSPEC, 1, 1);
  lua_setfield(L, -2, "stdout");
  nbio_push_handle(L, 2, AF_UNSPEC, 1, 1);
  lua_setfield(L, -2, "stderr");
#ifdef NBIO_IGNORE_SIGPIPE_COMPLETELY
  signal(SIGPIPE, SIG_IGN);
#endif
  return 1;
}
