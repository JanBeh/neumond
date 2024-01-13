#include <stdlib.h>
#include <signal.h>
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

#include <lua.h>
#include <lauxlib.h>

#define NBIO_CHUNKSIZE 8192
#define NBIO_LISTEN_BACKLOG 256

#define NBIO_OPEN_DEFAULT_FLAGS "r"

#define NBIO_MAXSTRERRORLEN 160
#define NBIO_STRERROR_R_MSG "error detail unavailable due to noncompliant strerror_r() implementation"

#define NBIO_SUN_PATH_MAXLEN (sizeof(struct sockaddr_un) - offsetof(struct sockaddr_un, sun_path) - 1)

#define nbio_prepare_errmsg(errcode) \
  char errmsg[NBIO_MAXSTRERRORLEN] = NBIO_STRERROR_R_MSG; \
  strerror_r((errcode), errmsg, NBIO_MAXSTRERRORLEN)

#define NBIO_HANDLE_MT_REGKEY "nbio_handle"
#define NBIO_LISTENER_MT_REGKEY "nbio_listener"
#define NBIO_HANDLE_METHODS_UPIDX 1
#define NBIO_LISTENER_METHODS_UPIDX 1

typedef struct {
  int fd;
  sa_family_t addrfam;
  int shared;
  void *readbuf;
  size_t readbuf_capacity;
  size_t readbuf_written;
  size_t readbuf_read;
  int readbuf_checked_terminator;
  void *writebuf;
  size_t writebuf_written;
  size_t writebuf_read;
  int nopush;
} nbio_handle_t;

typedef struct {
  int fd;
  sa_family_t addrfam;
} nbio_listener_t;

static void nbio_handle_set_nopush(
  lua_State *L, nbio_handle_t *handle, int nopush
) {
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
    luaL_error(L, "setsockopt TCP_NOPUSH=%d failed: %s", nopush, errmsg);
  }
#elif defined(TCP_CORK)
  if (
    setsockopt(handle->fd, IPPROTO_TCP, TCP_CORK, &nopush, sizeof(nopush))
  ) {
    nbio_prepare_errmsg(errno);
    luaL_error(L, "setsockopt TCP_CORK=%d failed: %s", nopush, errmsg);
  }
#endif
#else
#warning Neither TCP_NOPUSH nor TCP_CORK is available.
#endif
}

static int nbio_push_handle(
  lua_State *L, int fd, sa_family_t addrfam, int shared
) {
  // TODO: catch out-of-memory error
  nbio_handle_t *handle = lua_newuserdatauv(L, sizeof(*handle), 0);
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

static int nbio_handle_close(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  if (handle->fd != -1 && !handle->shared) close(handle->fd);
  handle->fd = -1;
  free(handle->readbuf);
  handle->readbuf = NULL;
  free(handle->writebuf);
  handle->writebuf = NULL;
  return 0;
}

static int nbio_listener_close(lua_State *L) {
  nbio_listener_t *listener = luaL_checkudata(L, 1, NBIO_LISTENER_MT_REGKEY);
  if (listener->fd != -1) close(listener->fd);
  listener->fd = -1;
  return 0;
}

static int nbio_cmp_flag(const char *s, size_t len, const char *f) {
  for (size_t i=0; i<len; i++) {
    if (s[i] != f[i] || !f[i]) return -1;
  }
  if (f[len]) return -1;
  return 0;
}

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
        else if (!nbio_cmp_flag(s, k, "exclusive")) flags |= O_EXCL;
        else if (!nbio_cmp_flag(s, k, "sharedlock")) flags |= O_SHLOCK;
        else if (!nbio_cmp_flag(s, k, "exclusivelock")) flags |= O_EXLOCK;
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
  return nbio_push_handle(L, fd, AF_UNSPEC, 0);
}

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
  return nbio_push_handle(L, fd, AF_LOCAL, 0);
}

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
  return nbio_push_handle(L, fd, addrfam, 0);
}

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
  if (stat(path, &sb) == 0) {
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
    static const int reuseval = 1;
    if (setsockopt(
      fd, SOL_SOCKET, SO_REUSEADDR, &reuseval, sizeof(reuseval)
    )) {
      nbio_prepare_errmsg(errno);
      freeaddrinfo(res);
      close(fd);
      lua_pushnil(L);
      lua_pushfstring(L, "cannot set SO_REUSEADDR socket option: %s", errmsg);
      return 2;
    }
  }
  if (addrinfo->ai_family == AF_INET6) {
    const int ipv6onlyval = (host != NULL) ? 1 : 0;
    if (setsockopt(
      fd, IPPROTO_IPV6, IPV6_V6ONLY, &ipv6onlyval, sizeof(ipv6onlyval)
    )) {
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

static int nbio_handle_index(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  const char *key = lua_tostring(L, 2);
  if (key) {
    if (!strcmp(key, "fd")) {
      lua_pushinteger(L, handle->fd);
      return 1;
    }
  }
  lua_settop(L, 2);
  lua_gettable(L, lua_upvalueindex(NBIO_HANDLE_METHODS_UPIDX));
  return 1;
}

static int nbio_listener_index(lua_State *L) {
  nbio_listener_t *listener = luaL_checkudata(L, 1, NBIO_LISTENER_MT_REGKEY);
  const char *key = lua_tostring(L, 2);
  if (key) {
    if (!strcmp(key, "fd")) {
      lua_pushinteger(L, listener->fd);
      return 1;
    }
  }
  lua_settop(L, 2);
  lua_gettable(L, lua_upvalueindex(NBIO_LISTENER_METHODS_UPIDX));
  return 1;
}

static int nbio_handle_read_unbuffered(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  lua_Integer maxlen = luaL_optinteger(L, 2, NBIO_CHUNKSIZE);
  if (handle->fd == -1) {
    return luaL_error(L, "read from closed handle");
  }
  if (maxlen <= 0) {
    return luaL_argerror(L, 2, "maximum byte count must be positive");
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

static int nbio_handle_read(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  lua_Integer maxlen = luaL_optinteger(L, 2, NBIO_CHUNKSIZE);
  size_t terminator_len;
  const char *terminator = lua_tolstring(L, 3, &terminator_len);
  if (handle->fd == -1) {
    return luaL_error(L, "read from closed handle");
  }
  if (maxlen <= 0) {
    return luaL_argerror(L, 2, "maximum byte count must be positive");
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

static int nbio_handle_write_unbuffered(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  size_t bufsize;
  const char *buf = luaL_checklstring(L, 2, &bufsize);
  lua_Integer start = luaL_optinteger(L, 3, 1);
  if (bufsize > LUA_MAXINTEGER) {
    return luaL_error(L, "chunk length longer than LUA_MAXINTEGER");
  }
  lua_Integer end = luaL_optinteger(L, 4, (lua_Integer)bufsize);
  nbio_handle_set_nopush(L, handle, 0);
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

static int nbio_handle_write(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  size_t bufsize;
  const char *buf = luaL_checklstring(L, 2, &bufsize);
  lua_Integer start = luaL_optinteger(L, 3, 1);
  if (bufsize > LUA_MAXINTEGER) {
    return luaL_error(L, "chunk length longer than LUA_MAXINTEGER");
  }
  lua_Integer end = luaL_optinteger(L, 4, (lua_Integer)bufsize);
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

static int nbio_handle_flush(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  if (handle->writebuf_written > 0) {
    size_t written = write(
      handle->fd,
      handle->writebuf + handle->writebuf_read,
      handle->writebuf_written - handle->writebuf_read
    );
    if (written >= 0) {
      handle->writebuf_read += written;
    } else if (errno == EAGAIN || errno == EINTR) {
      // nothing
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
  size_t remaining = handle->writebuf_written - handle->writebuf_read;
  if (remaining == 0) {
    handle->writebuf_written = 0;
    handle->writebuf_read = 0;
    nbio_handle_set_nopush(L, handle, 0);
    nbio_handle_set_nopush(L, handle, 1);
  }
  lua_pushinteger(L, remaining);
  return 1;
}

static int nbio_listener_accept(lua_State *L) {
  nbio_listener_t *listener = luaL_checkudata(L, 1, NBIO_LISTENER_MT_REGKEY);
  if (listener->fd == -1) luaL_error(L, "attempt to use closed listener");
  int fd;
  while (1) {
#if defined(__linux__) && !defined(_GNU_SOURCE)
    fd = accept(listener->fd, NULL, NULL);
    if (fd != -1) {
      if (fcntl(fd, F_SETFD, FD_CLOEXEC) == -1) {
        nbio_prepare_errmsg(errno);
        close(fd);
        luaL_error(L, "error in fcntl call: %s", errmsg);
      }
    }
#else
    fd = accept4(listener->fd, NULL, NULL, SOCK_CLOEXEC);
#endif
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
        luaL_error(L, "error in fcntl call: %s", errmsg);
      }
      flags |= O_NONBLOCK;
      if (fcntl(fd, F_SETFL, flags) == -1) {
        nbio_prepare_errmsg(errno);
        close(fd);
        luaL_error(L, "error in fcntl call: %s", errmsg);
      }
      return nbio_push_handle(L, fd, listener->addrfam, 0);
    }
  }
}

static const struct luaL_Reg nbio_module_funcs[] = {
  {"open", nbio_open},
  {"localconnect", nbio_localconnect},
  {"tcpconnect", nbio_tcpconnect},
  {"locallisten", nbio_locallisten},
  {"tcplisten", nbio_tcplisten},
  {NULL, NULL}
};

static const struct luaL_Reg nbio_handle_methods[] = {
  {"close", nbio_handle_close},
  {"read_unbuffered", nbio_handle_read_unbuffered},
  {"read", nbio_handle_read},
  {"write_unbuffered", nbio_handle_write_unbuffered},
  {"write", nbio_handle_write},
  {"flush", nbio_handle_flush},
  {NULL, NULL}
};

static const struct luaL_Reg nbio_listener_methods[] = {
  {"accept", nbio_listener_accept},
  {NULL, NULL}
};

static const struct luaL_Reg nbio_handle_metamethods[] = {
  {"__close", nbio_handle_close},
  {"__gc", nbio_handle_close},
  {"__index", nbio_handle_index},
  {NULL, NULL}
};

static const struct luaL_Reg nbio_listener_metamethods[] = {
  {"__close", nbio_listener_close},
  {"__gc", nbio_listener_close},
  {"__index", nbio_listener_index},
  {NULL, NULL}
};

int luaopen_nbio(lua_State *L) {
  signal(SIGPIPE, SIG_IGN);  // generate I/O errors instead of signal 13
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
  lua_newtable(L);
  luaL_setfuncs(L, nbio_module_funcs, 0);
  nbio_push_handle(L, 0, AF_UNSPEC, 1);
  lua_setfield(L, -2, "stdin");
  nbio_push_handle(L, 1, AF_UNSPEC, 1);
  lua_setfield(L, -2, "stdout");
  nbio_push_handle(L, 2, AF_UNSPEC, 1);
  lua_setfield(L, -2, "stderr");
  return 1;
}
