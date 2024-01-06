#include <stdlib.h>
#include <signal.h>
#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#include <unistd.h>
#include <fcntl.h>

#include <lua.h>
#include <lauxlib.h>

#define NBIO_BUFSIZE 4096
#define NBIO_LISTEN_BACKLOG 256

#define NBIO_MAXSTRERRORLEN 160
#define NBIO_STRERROR_R_MSG "error detail unavailable due to noncompliant strerror_r() implementation"
#define nbio_prepare_errmsg(errcode) \
  char errmsg[NBIO_MAXSTRERRORLEN] = NBIO_STRERROR_R_MSG; \
  strerror_r((errcode), errmsg, NBIO_MAXSTRERRORLEN)

#define NBIO_HANDLE_MT_REGKEY "nbio_handle"
#define NBIO_LISTENER_MT_REGKEY "nbio_listener"
#define NBIO_HANDLE_METHODS_UPIDX 1
#define NBIO_LISTENER_METHODS_UPIDX 1

typedef struct {
  int fd;
  int dont_close;
  void *buf;
} nbio_handle_t;

typedef struct {
  int fd;
  sa_family_t addrfam;
} nbio_listener_t;

static int nbio_push_handle(lua_State *L, int fd, int dont_close) {
  nbio_handle_t *handle = lua_newuserdatauv(L, sizeof(*handle), 0);
  handle->buf = malloc(NBIO_BUFSIZE);
  if (!handle->buf) {
    close(fd);
    return luaL_error(L, "buffer allocation failed");
  }
  handle->fd = fd;
  handle->dont_close = dont_close;
  luaL_setmetatable(L, NBIO_HANDLE_MT_REGKEY);
  return 1;
}

static int nbio_handle_close(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  if (handle->fd != -1 && !handle->dont_close) close(handle->fd);
  handle->fd = -1;
  free(handle->buf);
  handle->buf = NULL;
  return 0;
}

static int nbio_listener_close(lua_State *L) {
  nbio_listener_t *listener = luaL_checkudata(L, 1, NBIO_LISTENER_MT_REGKEY);
  if (listener->fd != -1) close(listener->fd);
  listener->fd = -1;
  return 0;
}

static int nbio_stdin(lua_State *L) {
  return nbio_push_handle(L, 0, 1);
}

static int nbio_stdout(lua_State *L) {
  return nbio_push_handle(L, 1, 1);
}

static int nbio_stderr(lua_State *L) {
  return nbio_push_handle(L, 2, 1);
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
  return nbio_push_handle(L, fd, 0);
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
  nbio_listener_t *listener = lua_newuserdatauv(L, sizeof(*listener), 0);
  listener->addrfam = addrinfo->ai_family;
  listener->fd = socket(
    addrinfo->ai_family,  // incorrect to not use PF_* but AF_* constants here
    addrinfo->ai_socktype | SOCK_CLOEXEC | SOCK_NONBLOCK,
    addrinfo->ai_protocol
  );
  if (listener->fd == -1) {
    nbio_prepare_errmsg(errno);
    freeaddrinfo(res);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  {
    static const int reuseval = 1;
    if (setsockopt(
      listener->fd, SOL_SOCKET, SO_REUSEADDR, &reuseval, sizeof(reuseval)
    )) {
      nbio_prepare_errmsg(errno);
      freeaddrinfo(res);
      close(listener->fd);
      lua_pushnil(L);
      lua_pushfstring(L, "cannot set SO_REUSEADDR socket option: %s", errmsg);
      return 2;
    }
  }
  if (addrinfo->ai_family == AF_INET6) {
    const int ipv6onlyval = (host != NULL) ? 1 : 0;
    if (setsockopt(
      listener->fd, IPPROTO_IPV6, IPV6_V6ONLY,
      &ipv6onlyval, sizeof(ipv6onlyval)
    )) {
      nbio_prepare_errmsg(errno);
      freeaddrinfo(res);
      close(listener->fd);
      lua_pushnil(L);
      lua_pushfstring(L, "cannot set IPV6_V6ONLY socket option: %s", errmsg);
      return 2;
    }
  }
  if (bind(listener->fd, addrinfo->ai_addr, addrinfo->ai_addrlen)) {
    nbio_prepare_errmsg(errno);
    freeaddrinfo(res);
    close(listener->fd);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  freeaddrinfo(res);
  if (listen(listener->fd, NBIO_LISTEN_BACKLOG)) {
    nbio_prepare_errmsg(errno);
    close(listener->fd);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
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

static int nbio_handle_read(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  lua_Integer bufsize = luaL_optinteger(L, 2, NBIO_BUFSIZE);
  if (handle->fd == -1) {
    return luaL_error(L, "read from closed handle");
  }
  if (bufsize <= 0) {
    return luaL_argerror(L, 2, "maximum byte count must be positive");
  }
  if (bufsize > NBIO_BUFSIZE) bufsize = NBIO_BUFSIZE;
  while (1) {
    ssize_t used = read(handle->fd, handle->buf, bufsize);
    if (used > 0) {
      lua_pushlstring(L, handle->buf, used);
      return 1;
    } else if (used == 0) {
      lua_pushboolean(L, 0);
      lua_pushliteral(L, "end of data");
      return 2;
    } else if (errno == EAGAIN) {
      lua_pushlstring(L, NULL, 0);
      return 1;
    } else if (errno != EINTR) {
      nbio_prepare_errmsg(errno);
      lua_pushnil(L);
      lua_pushstring(L, errmsg);
      return 2;
    }
  }
}

static int nbio_handle_write(lua_State *L) {
  nbio_handle_t *handle = luaL_checkudata(L, 1, NBIO_HANDLE_MT_REGKEY);
  size_t bufsize;
  const char *buf = luaL_checklstring(L, 2, &bufsize);
  lua_Integer start = luaL_optinteger(L, 3, 1);
  lua_Integer end = luaL_optinteger(L, 4, bufsize); // TODO: cast?
  if (start <= -bufsize) start = 1;
  else if (start < 0) start = bufsize + start + 1;
  else if (start == 0) start = 1;
  if (end < 0) end = bufsize + end + 1;
  else if (end > bufsize) end = bufsize;
  if (end < start) {
    start = 1;
    end = 0;
  }
  while (1) {
    ssize_t written = write(handle->fd, buf+start-1, end+1-start);
    if (written >= 0) {
      lua_pushinteger(L, written);
      return 1;
    } else if (errno == EAGAIN) {
      lua_pushinteger(L, 0);
      return 1;
    } else if (errno == EPIPE) {
      lua_pushboolean(L, 0);
      lua_pushliteral(L, "peer closed stream");
      return 2;
    } else if (errno != EINTR) {
      nbio_prepare_errmsg(errno);
      lua_pushnil(L);
      lua_pushstring(L, errmsg);
      return 2;
    }
  }
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
      return nbio_push_handle(L, fd, 0);
    }
  }
}

static const struct luaL_Reg nbio_module_funcs[] = {
  {"stdin", nbio_stdin},
  {"stdout", nbio_stdout},
  {"stderr", nbio_stderr},
  {"tcpconnect", nbio_tcpconnect},
  {"tcplisten", nbio_tcplisten},
  {NULL, NULL}
};

static const struct luaL_Reg nbio_handle_methods[] = {
  {"close", nbio_handle_close},
  {"read", nbio_handle_read},
  {"write", nbio_handle_write},
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
  return 1;
}
