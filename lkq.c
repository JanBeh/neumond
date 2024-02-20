#define _POSIX_C_SOURCE 200809L
#ifdef _GNU_SOURCE
#error Defining _GNU_SOURCE may result in non-compliant strerror_r definition.
#endif

#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/event.h>
#include <signal.h>

#include <lua.h>
#include <lauxlib.h>

#define LKQ_EVENT_COUNT 64

#define LKQ_MAXSTRERRORLEN 1024
#define LKQ_STRERROR_R_MSG "error detail unavailable due to noncompliant strerror_r() implementation"
#define lkq_prepare_errmsg(errcode) \
  char errmsg[LKQ_MAXSTRERRORLEN] = LKQ_STRERROR_R_MSG; \
  strerror_r((errcode), errmsg, LKQ_MAXSTRERRORLEN)

#define LKQ_QUEUE_MT_REGKEY "lkq_queue"
#define LKQ_TIMER_MT_REGKEY "lkq_timer"

#define LKQ_QUEUE_CALLBACK_ARGS_UVIDX 1
#define LKQ_QUEUE_UVCNT 1

typedef struct {
  int fd;
} lkq_queue_t;

static void lkq_push_filterid(lua_State *L, uintptr_t ident, short filter) {
  luaL_Buffer buf;
  luaL_buffinitsize(L, &buf, sizeof(ident) + sizeof(filter));
  luaL_addlstring(&buf, (void *)&ident, sizeof(ident));
  luaL_addlstring(&buf, (void *)&filter, sizeof(filter));
  luaL_pushresult(&buf);
}

static int lkq_new_queue(lua_State *L) {
  lkq_queue_t *queue = lua_newuserdatauv(L, sizeof(*queue), LKQ_QUEUE_UVCNT);
  queue->fd = -1;
  lua_newtable(L);
  lua_setiuservalue(L, -2, LKQ_QUEUE_CALLBACK_ARGS_UVIDX);
  luaL_setmetatable(L, LKQ_QUEUE_MT_REGKEY);
  queue->fd = kqueue();
  if (queue->fd == -1) {
    lkq_prepare_errmsg(errno);
    return luaL_error(L, "could not create kqueue: %s", errmsg);
  }
  return 1;
}

static int lkq_close(lua_State *L) {
  lkq_queue_t *queue = luaL_checkudata(L, 1, LKQ_QUEUE_MT_REGKEY);
  if (queue->fd != -1) close(queue->fd);
  queue->fd = -1;
  return 0;
}

static lkq_queue_t *lkq_check_queue(lua_State *L, int idx) {
  lkq_queue_t *queue = luaL_checkudata(L, idx, LKQ_QUEUE_MT_REGKEY);
  if (queue->fd == -1) luaL_argerror(L, idx, "kqueue has been closed");
  return queue;
}

static int lkq_deregister_fd(lua_State *L) {
  lkq_queue_t *queue = lkq_check_queue(L, 1);
  int fd = luaL_checkinteger(L, 2);
  lua_getiuservalue(L, 1, LKQ_QUEUE_CALLBACK_ARGS_UVIDX);
  lkq_push_filterid(L, fd, EVFILT_READ);
  lua_pushnil(L);
  lua_rawset(L, -3);
  lkq_push_filterid(L, fd, EVFILT_WRITE);
  lua_pushnil(L);
  lua_rawset(L, -3);
  struct kevent event[2];
  EV_SET(event+0, fd, EVFILT_READ, EV_DELETE | EV_RECEIPT, 0, 0, NULL);
  EV_SET(event+1, fd, EVFILT_WRITE, EV_DELETE | EV_RECEIPT, 0, 0, NULL);
  struct kevent tevent[2];
  int nevent = kevent(queue->fd, event, 2, tevent, 2, NULL);
  if (nevent == -1) {
    if (errno != EINTR) {
      lkq_prepare_errmsg(errno);
      return luaL_error(L,
        "deregistering file descriptor %d failed: %s", fd, errmsg
      );
    }
  } else if (nevent != 2) {
    return luaL_error(L,
      "deregistering file descriptor %d failed: got wrong number of receipts",
      fd
    );
  } else {
    for (int i=0; i<2; i++) {
      if (tevent[i].flags & EV_ERROR) {
        int err = tevent[i].data;
        if (err && err != ENOENT) {
          lkq_prepare_errmsg(err);
          return luaL_error(L,
            "deregistering file descriptor %d failed: %s", fd, errmsg
          );
        }
      } else {
        return luaL_error(L,
          "deregistering file descriptor %d failed: returned event is not a receipt",
          fd
        );
      }
    }
  }
  return 0;
}

static int lkq_add_fd_read_impl(lua_State *L, unsigned short flags) {
  lkq_queue_t *queue = lkq_check_queue(L, 1);
  int fd = luaL_checkinteger(L, 2);
  struct kevent event;
  EV_SET(&event, fd, EVFILT_READ, flags, 0, 0, NULL);
  int nevent = kevent(queue->fd, &event, 1, NULL, 0, NULL);
  if (nevent == -1 && errno != EINTR) {
    lkq_prepare_errmsg(errno);
    return luaL_error(L,
      "registering file descriptor %d for reading failed: %s",
      fd, errmsg
    );
  }
  lua_settop(L, 3);
  lua_getiuservalue(L, 1, LKQ_QUEUE_CALLBACK_ARGS_UVIDX);
  lkq_push_filterid(L, fd, EVFILT_READ);
  lua_pushvalue(L, 3);
  lua_rawset(L, 4);
  return 0;
}

static int lkq_add_fd_read_once(lua_State *L) {
  return lkq_add_fd_read_impl(L, EV_ADD | EV_ONESHOT);
}

static int lkq_add_fd_read(lua_State *L) {
  return lkq_add_fd_read_impl(L, EV_ADD);
}

static int lkq_remove_fd_read(lua_State *L) {
  lkq_queue_t *queue = lkq_check_queue(L, 1);
  int fd = luaL_checkinteger(L, 2);
  lua_getiuservalue(L, 1, LKQ_QUEUE_CALLBACK_ARGS_UVIDX);
  lkq_push_filterid(L, fd, EVFILT_READ);
  lua_pushnil(L);
  lua_rawset(L, -3);
  struct kevent event;
  EV_SET(&event, fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
  int nevent = kevent(queue->fd, &event, 1, NULL, 0, NULL);
  if (nevent == -1 && errno != EINTR && errno != ENOENT) {
    lkq_prepare_errmsg(errno);
    return luaL_error(L,
      "deregistering file descriptor %d for reading failed: %s",
      fd, errmsg
    );
  }
  return 0;
}

static int lkq_add_fd_write_impl(lua_State *L, unsigned short flags) {
  lkq_queue_t *queue = lkq_check_queue(L, 1);
  int fd = luaL_checkinteger(L, 2);
  struct kevent event;
  EV_SET(&event, fd, EVFILT_WRITE, flags, 0, 0, NULL);
  int nevent = kevent(queue->fd, &event, 1, NULL, 0, NULL);
  if (nevent == -1 && errno != EINTR) {
    lkq_prepare_errmsg(errno);
    return luaL_error(L,
      "registering file descriptor %d for writing failed: %s",
      fd, errmsg
    );
  }
  lua_settop(L, 3);
  lua_getiuservalue(L, 1, LKQ_QUEUE_CALLBACK_ARGS_UVIDX);
  lkq_push_filterid(L, fd, EVFILT_WRITE);
  lua_pushvalue(L, 3);
  lua_rawset(L, 4);
  return 0;
}

static int lkq_add_fd_write_once(lua_State *L) {
  return lkq_add_fd_write_impl(L, EV_ADD | EV_ONESHOT);
}

static int lkq_add_fd_write(lua_State *L) {
  return lkq_add_fd_write_impl(L, EV_ADD);
}

static int lkq_remove_fd_write(lua_State *L) {
  lkq_queue_t *queue = lkq_check_queue(L, 1);
  int fd = luaL_checkinteger(L, 2);
  lua_getiuservalue(L, 1, LKQ_QUEUE_CALLBACK_ARGS_UVIDX);
  lkq_push_filterid(L, fd, EVFILT_WRITE);
  lua_pushnil(L);
  lua_rawset(L, -3);
  struct kevent event;
  EV_SET(&event, fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
  int nevent = kevent(queue->fd, &event, 1, NULL, 0, NULL);
  if (nevent == -1 && errno != EINTR && errno != ENOENT) {
    lkq_prepare_errmsg(errno);
    return luaL_error(L,
      "deregistering file descriptor %d for writing failed: %s",
      fd, errmsg
    );
  }
  return 0;
}

static int lkq_add_signal(lua_State *L) {
  lkq_queue_t *queue = lkq_check_queue(L, 1);
  int sig = luaL_checkinteger(L, 2);
  struct kevent event;
  if (signal(sig, SIG_IGN) == SIG_ERR) {
    lkq_prepare_errmsg(errno);
    return luaL_error(L,
      "could not ignore signal %d prior to installing handler: %s", sig, errmsg
    );
  }
  EV_SET(&event, sig, EVFILT_SIGNAL, EV_ADD, 0, 0, NULL);
  int nevent = kevent(queue->fd, &event, 1, NULL, 0, NULL);
  if (nevent == -1 && errno != EINTR) {
    lkq_prepare_errmsg(errno);
    return luaL_error(L,
      "adding handler for signal %d failed: %s", sig, errmsg
    );
  }
  lua_settop(L, 3);
  lua_getiuservalue(L, 1, LKQ_QUEUE_CALLBACK_ARGS_UVIDX);
  lkq_push_filterid(L, sig, EVFILT_SIGNAL);
  lua_pushvalue(L, 3);
  lua_rawset(L, 4);
  return 0;
}

static int lkq_remove_signal(lua_State *L) {
  lkq_queue_t *queue = lkq_check_queue(L, 1);
  int sig = luaL_checkinteger(L, 2);
  lua_getiuservalue(L, 1, LKQ_QUEUE_CALLBACK_ARGS_UVIDX);
  lkq_push_filterid(L, sig, EVFILT_SIGNAL);
  lua_pushnil(L);
  lua_rawset(L, -3);
  struct kevent event;
  EV_SET(&event, sig, EVFILT_SIGNAL, EV_DELETE, 0, 0, NULL);
  int nevent = kevent(queue->fd, &event, 1, NULL, 0, NULL);
  if (nevent == -1 && errno != EINTR && errno != ENOENT) {
    lkq_prepare_errmsg(errno);
    return luaL_error(L,
      "removing handler for signal %d failed: %s", sig, errmsg
    );
  }
  return 0;
}

static int lkq_add_pid(lua_State *L) {
  lkq_queue_t *queue = lkq_check_queue(L, 1);
  int pid = luaL_checkinteger(L, 2);
  struct kevent event;
  EV_SET(&event, pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
  int nevent = kevent(queue->fd, &event, 1, NULL, 0, NULL);
  if (nevent == -1 && errno != EINTR) {
    lkq_prepare_errmsg(errno);
    return luaL_error(L,
      "adding handler for pid %d failed: %s", pid, errmsg
    );
  }
  lua_settop(L, 3);
  lua_getiuservalue(L, 1, LKQ_QUEUE_CALLBACK_ARGS_UVIDX);
  lkq_push_filterid(L, pid, EVFILT_PROC);
  lua_pushvalue(L, 3);
  lua_rawset(L, 4);
  return 0;
}

static int lkq_remove_pid(lua_State *L) {
  lkq_queue_t *queue = lkq_check_queue(L, 1);
  int pid = luaL_checkinteger(L, 2);
  lua_getiuservalue(L, 1, LKQ_QUEUE_CALLBACK_ARGS_UVIDX);
  lkq_push_filterid(L, pid, EVFILT_SIGNAL);
  lua_pushnil(L);
  lua_rawset(L, -3);
  struct kevent event;
  EV_SET(&event, pid, EVFILT_PROC, EV_DELETE, 0, 0, NULL);
  int nevent = kevent(queue->fd, &event, 1, NULL, 0, NULL);
  if (nevent == -1 && errno != EINTR && errno != ENOENT) {
    lkq_prepare_errmsg(errno);
    return luaL_error(L,
      "removing handler for pid %d failed: %s", pid, errmsg
    );
  }
  return 0;
}

static int lkq_add_timeout(lua_State *L) {
  lkq_queue_t *queue = lkq_check_queue(L, 1);
  lua_Number seconds = luaL_checknumber(L, 2);
  lua_settop(L, 3);
  void *timerid = lua_newuserdatauv(L, 1, 0);
  struct kevent event;
  EV_SET(
    &event,
    (uintptr_t)timerid,
    EVFILT_TIMER,
    EV_ADD | EV_ONESHOT,
    NOTE_NSECONDS,
    seconds * 1e9,
    NULL
  );
  int nevent = kevent(queue->fd, &event, 1, NULL, 0, NULL);
  if (nevent == -1 && errno != EINTR) {
    lkq_prepare_errmsg(errno);
    return luaL_error(L, "registering timeout timer failed: %s", errmsg);
  }
  luaL_setmetatable(L, LKQ_TIMER_MT_REGKEY);
  lua_getiuservalue(L, 1, LKQ_QUEUE_CALLBACK_ARGS_UVIDX);
  lkq_push_filterid(L, (uintptr_t)timerid, EVFILT_TIMER);
  lua_pushvalue(L, 3);
  lua_rawset(L, 5);
  lua_settop(L, 4);
  return 1;
}

static int lkq_remove_timeout(lua_State *L) {
  lkq_queue_t *queue = lkq_check_queue(L, 1);
  void *timerid = luaL_checkudata(L, 2, LKQ_TIMER_MT_REGKEY);
  lua_getiuservalue(L, 1, LKQ_QUEUE_CALLBACK_ARGS_UVIDX);
  lkq_push_filterid(L, (uintptr_t)timerid, EVFILT_TIMER);
  lua_pushnil(L);
  lua_rawset(L, -3);
  struct kevent event;
  EV_SET(&event, (uintptr_t)timerid, EVFILT_TIMER, EV_DELETE, 0, 0, NULL);
  int nevent = kevent(queue->fd, &event, 1, NULL, 0, NULL);
  if (nevent == -1 && errno != EINTR) {
    lkq_prepare_errmsg(errno);
    return luaL_error(L, "deregistering timeout timer failed: %s", errmsg);
  }
  return 0;
}

typedef struct {
  struct kevent tevent[LKQ_EVENT_COUNT];
  int nevent;
  int i;
} lkq_wait_state_t;

static int lkq_wait_cont(lua_State *L, int status, lua_KContext ctx) {
  // elements on stack:
  // 1: queue
  // 2: optional callback function
  // 3: state userdata allocation
  // 4: callback arguments table
  lkq_wait_state_t *state = (lkq_wait_state_t *)ctx;
  while (state->i < state->nevent) {
    lua_pushvalue(L, 2); // optional callback function at stack position 5
    // get callback arg:
    lkq_push_filterid(
      L, state->tevent[state->i].ident, state->tevent[state->i].filter
    );
    lua_rawget(L, 4); // callback argument at stack position 6
    if (state->tevent[state->i].flags & EV_ONESHOT) {
      // remove callback argument from table:
      lkq_push_filterid(
        L, state->tevent[state->i].ident, state->tevent[state->i].filter
      );
      lua_pushnil(L);
      lua_rawset(L, 4);
    }
    state->i++;
    // elements on stack:
    // 5: optional callback function
    // 6: callback argument
    if (lua_isnil(L, 5)) {
      lua_settop(L, 4);
    } else {
      lua_callk(L, 1, 0, ctx, lkq_wait_cont);
    }
  }
  lua_pushinteger(L, state->nevent);
  return 1;
}

static int lkq_wait_impl(lua_State *L, int pollonly) {
  const static struct timespec zerotime = { 0, };
  lkq_queue_t *queue = lkq_check_queue(L, 1);
  struct kevent tevent[LKQ_EVENT_COUNT];
  int nevent;
  while (1) {
    nevent = kevent(
      queue->fd, NULL, 0, tevent, LKQ_EVENT_COUNT, pollonly ? &zerotime : NULL
    );
    if (nevent != -1) break;
    if (errno != EINTR) {
      lkq_prepare_errmsg(errno);
      return luaL_error(L, "polling kqueue failed: %s", errmsg);
    }
    if (pollonly) break;
  }
  if (nevent > 0) {
    lua_settop(L, 2); // optional callback function at stack position 2
    lkq_wait_state_t *state = lua_newuserdata(L, sizeof(*state)); // pos 3
    memcpy(state->tevent, tevent, nevent * sizeof(*tevent));
    state->nevent = nevent;
    state->i = 0;
    lua_getiuservalue(L, 1, LKQ_QUEUE_CALLBACK_ARGS_UVIDX); // cb args tbl at 4
    return lkq_wait_cont(L, LUA_OK, (lua_KContext)state);
  }
  lua_pushinteger(L, nevent);
  return 1;
}

static int lkq_wait(lua_State *L) {
  return lkq_wait_impl(L, 0);
}

static int lkq_poll(lua_State *L) {
  return lkq_wait_impl(L, 1);
}

static const struct luaL_Reg lkq_queue_methods[] = {
  {"close", lkq_close},
  {"deregister_fd", lkq_deregister_fd},
  {"add_fd_read_once", lkq_add_fd_read_once},
  {"add_fd_read", lkq_add_fd_read},
  {"remove_fd_read", lkq_remove_fd_read},
  {"add_fd_write_once", lkq_add_fd_write_once},
  {"add_fd_write", lkq_add_fd_write},
  {"remove_fd_write", lkq_remove_fd_write},
  {"add_signal", lkq_add_signal},
  {"remove_signal", lkq_remove_signal},
  {"add_pid", lkq_add_pid},
  {"remove_pid", lkq_remove_pid},
  {"add_timeout", lkq_add_timeout},
  {"remove_timeout", lkq_remove_timeout},
  {"wait", lkq_wait},
  {"poll", lkq_poll},
  {NULL, NULL}
};

static const struct luaL_Reg lkq_queue_metamethods[] = {
  {"__close", lkq_close},
  {"__gc", lkq_close},
  {NULL, NULL}
};

static const struct luaL_Reg lkq_module_funcs[] = {
  {"new_queue", lkq_new_queue},
  {NULL, NULL}
};

int luaopen_lkq(lua_State *L) {
  luaL_newmetatable(L, LKQ_QUEUE_MT_REGKEY);
  luaL_setfuncs(L, lkq_queue_metamethods, 0);
  lua_newtable(L);
  luaL_setfuncs(L, lkq_queue_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newmetatable(L, LKQ_TIMER_MT_REGKEY);
  lua_pop(L, 1);
  lua_newtable(L);
  luaL_setfuncs(L, lkq_module_funcs, 0);
  return 1;
}
