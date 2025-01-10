#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>
#include <libpq-fe.h>

// NOTE: only needed for notice processor:
#define PGEFF_MODULE_REGKEY "pgeff_module"

#define PGEFF_DBCONN_MT_REGKEY "pgeff_dbconn"
#define PGEFF_TMPRES_MT_REGKEY "pgeff_tmpres"
#define PGEFF_TMPNFY_MT_REGKEY "pgeff_tmpnfy"
#define PGEFF_RESULT_MT_REGKEY "pgeff_result"
#define PGEFF_ERROR_MT_REGKEY "pgeff_error"

#define PGEFF_MODULE_UPVALIDX 1
#define PGEFF_NOTIFY_UPVALIDX 2
#define PGEFF_SELECT_UPVALIDX 3
#define PGEFF_DEREGISTER_FD_UPVALIDX 4

#define PGEFF_METHODS_UPVALIDX 5

#define PGEFF_DBCONN_ATTR_USERVALIDX 1
#define PGEFF_DBCONN_QUERY_SLEEPER_USERVALIDX 2
#define PGEFF_DBCONN_QUERY_WAKER_USERVALIDX 3
#define PGEFF_DBCONN_LISTEN_SLEEPER_USERVALIDX 4
#define PGEFF_DBCONN_LISTEN_WAKER_USERVALIDX 5
#define PGEFF_DBCONN_USERVAL_COUNT 5

#define PGEFF_SQLTYPE_OTHER 0
#define PGEFF_SQLTYPE_BOOL 1
#define PGEFF_SQLTYPE_INT 2
#define PGEFF_SQLTYPE_FLOAT 3

#define PGEFF_OID_BOOL 16

static int pgeff_sqltype(Oid oid) {
  switch (oid) {
    case 16:   /* BOOL */
      return PGEFF_SQLTYPE_BOOL;
    case 20:   /* INT8 */
    case 21:   /* INT2 */
    case 23:   /* INT4 */
    case 26:   /* OID  */
    case 28:   /* XID  */
    case 5069: /* XID8 */
      return PGEFF_SQLTYPE_INT;
    case 700:  /* FLOAT4 */
    case 701:  /* FLOAT8 */
      return PGEFF_SQLTYPE_FLOAT;
    default:
      return PGEFF_SQLTYPE_OTHER;
  }
}

typedef struct {
  PGconn *pgconn;
  int query_waiting;
  int listen_waiting;
} pgeff_dbconn_t;

typedef struct {
  PGresult *pgres;
} pgeff_tmpres_t;

typedef struct {
  PGnotify *pgnfy;
} pgeff_tmpnfy_t;

static void pgeff_push_string_trim(lua_State *L, const char *s) {
  size_t len = strlen(s);
  if (s[len-1] == '\n') len--;
  lua_pushlstring(L, s, len);
}

static void pgeff_notice_processor(void *ptr, const char *message) {
  lua_State *const L = ptr;
  lua_getfield(L, LUA_REGISTRYINDEX, PGEFF_MODULE_REGKEY);
  lua_getfield(L, -1, "notice_processor");
  lua_remove(L, -2);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
  } else {
    pgeff_push_string_trim(L, message);
    lua_call(L, 1, 0);
  }
}

static int pgeff_dbconn_close_cont(
  lua_State *L, int status, lua_KContext ctx
) {
  pgeff_dbconn_t *dbconn = (pgeff_dbconn_t *)ctx;
  if (dbconn->pgconn) {
    PQfinish(dbconn->pgconn);
    dbconn->pgconn = NULL;
  }
  return 0;
}

static int pgeff_dbconn_close(lua_State *L) {
  pgeff_dbconn_t *dbconn = luaL_checkudata(L, 1, PGEFF_DBCONN_MT_REGKEY);
  int fd = PQsocket(dbconn->pgconn);
  if (fd != -1) {
    lua_pushvalue(L, lua_upvalueindex(PGEFF_DEREGISTER_FD_UPVALIDX));
    lua_pushinteger(L, fd);
    lua_callk(L, 1, 0, (lua_KContext)dbconn, pgeff_dbconn_close_cont);
  }
  return pgeff_dbconn_close_cont(L, LUA_OK, (lua_KContext)dbconn);
}

static int pgeff_tmpres_gc(lua_State *L) {
  // luaL_checkudata not necessary as userdata value is never exposed to user
  pgeff_tmpres_t *tmpres = lua_touserdata(L, 1);
  if (tmpres->pgres) {
    PQclear(tmpres->pgres);
    // setting to NULL not necessary as __gc metamethod is only called once
  }
  return 0;
}

static int pgeff_tmpnfy_gc(lua_State *L) {
  // luaL_checkudata not necessary as userdata value is never exposed to user
  pgeff_tmpnfy_t *tmpnfy = lua_touserdata(L, 1);
  if (tmpnfy->pgnfy) {
    PQfreemem(tmpnfy->pgnfy);
    // setting to NULL not necessary as __gc metamethod is only called once
  }
  return 0;
}

static int pgeff_dbconn_index(lua_State *L) {
  luaL_checkudata(L, 1, PGEFF_DBCONN_MT_REGKEY);
  lua_settop(L, 2);
  lua_getiuservalue(L, 1, PGEFF_DBCONN_ATTR_USERVALIDX);
  lua_pushvalue(L, 2);
  lua_rawget(L, -2);
  if (!lua_isnil(L, -1)) return 1;
  lua_settop(L, 2);
  lua_rawget(L, lua_upvalueindex(PGEFF_METHODS_UPVALIDX));
  return 1;
}

static int pgeff_dbconn_newindex(lua_State *L) {
  luaL_checkudata(L, 1, PGEFF_DBCONN_MT_REGKEY);
  lua_settop(L, 3);
  lua_getiuservalue(L, 1, PGEFF_DBCONN_ATTR_USERVALIDX);
  lua_insert(L, 2);
  lua_rawset(L, 2);
  return 0;
}

static int pgeff_connect_cont(lua_State *L, int status, lua_KContext ctx) {
  pgeff_dbconn_t *dbconn = (pgeff_dbconn_t *)ctx;
  while (1) {
    switch (PQconnectPoll(dbconn->pgconn)) {
      case PGRES_POLLING_OK:
        if (PQsetnonblocking(dbconn->pgconn, 1)) {
          lua_pushnil(L);
          pgeff_push_string_trim(L, PQerrorMessage(dbconn->pgconn));
          return 2;
        }
        return 1;
      case PGRES_POLLING_READING:
        lua_pushvalue(L, lua_upvalueindex(PGEFF_SELECT_UPVALIDX));
        lua_pushliteral(L, "fd_read");
        lua_pushinteger(L, PQsocket(dbconn->pgconn));
        lua_callk(L, 2, 0, ctx, pgeff_connect_cont);
        break;
      case PGRES_POLLING_WRITING:
        lua_pushvalue(L, lua_upvalueindex(PGEFF_SELECT_UPVALIDX));
        lua_pushliteral(L, "fd_write");
        lua_pushinteger(L, PQsocket(dbconn->pgconn));
        lua_callk(L, 2, 0, ctx, pgeff_connect_cont);
        break;
      case PGRES_POLLING_FAILED:
        lua_pushnil(L);
        pgeff_push_string_trim(L, PQerrorMessage(dbconn->pgconn));
        return 2;
      default:
        abort();
    }
  }
}

static int pgeff_connect_cont_notify(
  lua_State *L, int status, lua_KContext ctx
) {
  while (1) {
    if (ctx < 2) {
      ctx++;
      lua_pushvalue(L, lua_upvalueindex(PGEFF_NOTIFY_UPVALIDX));
      lua_callk(L, 0, 2, ctx, pgeff_connect_cont_notify);
    } else {
      lua_setiuservalue(L, -5, PGEFF_DBCONN_LISTEN_WAKER_USERVALIDX);
      lua_setiuservalue(L, -4, PGEFF_DBCONN_LISTEN_SLEEPER_USERVALIDX);
      lua_setiuservalue(L, -3, PGEFF_DBCONN_QUERY_WAKER_USERVALIDX);
      lua_setiuservalue(L, -2, PGEFF_DBCONN_QUERY_SLEEPER_USERVALIDX);
      return pgeff_connect_cont(L,
        LUA_OK, (lua_KContext)lua_touserdata(L, -1)
      );
    }
  }
}

static int pgeff_connect(lua_State *L) {
  const char *conninfo = luaL_checkstring(L, 1);
  pgeff_dbconn_t *dbconn = lua_newuserdatauv(L,
    sizeof(pgeff_dbconn_t), PGEFF_DBCONN_USERVAL_COUNT
  );
  lua_newtable(L);
  lua_setiuservalue(L, -2, PGEFF_DBCONN_ATTR_USERVALIDX);
  dbconn->pgconn = PQconnectStart(conninfo);
  if (!dbconn->pgconn) return luaL_error(L,
    "could not allocate memory for PGconn structure"
  );
  dbconn->query_waiting = 0;
  dbconn->listen_waiting = 0;
  luaL_setmetatable(L, PGEFF_DBCONN_MT_REGKEY);
  PQsetNoticeProcessor(dbconn->pgconn, pgeff_notice_processor, L);
  return pgeff_connect_cont_notify(L, LUA_OK, 0);
}

static int pgeff_query_cont(lua_State *L, int status, lua_KContext ctx) {
  pgeff_dbconn_t *dbconn = (pgeff_dbconn_t *)ctx;
  while (1) {
    dbconn->query_waiting = 0;
    if (!dbconn->pgconn) {
      return luaL_error(L, "database handle has been closed during query");
    }
    lua_getiuservalue(L, 1, PGEFF_DBCONN_LISTEN_WAKER_USERVALIDX);
    lua_call(L, 0, 0);
    int flushresult;
    if (
      !PQconsumeInput(dbconn->pgconn) ||
      (flushresult = PQflush(dbconn->pgconn), flushresult < 0)
    ) {
      lua_pushnil(L);
      lua_newtable(L);
      pgeff_push_string_trim(L, PQerrorMessage(dbconn->pgconn));
      lua_setfield(L, -2, "message");
      lua_pushliteral(L, "");
      lua_setfield(L, -2, "code");
      luaL_setmetatable(L, PGEFF_ERROR_MT_REGKEY);
      return 2;
    }
    while (!PQisBusy(dbconn->pgconn)) {
      PGresult *pgres = PQgetResult(dbconn->pgconn);
      if (!pgres) return lua_gettop(L) - 2;
      if (lua_type(L, 3) == LUA_TNIL) {
        PQclear(pgres);
        continue;
      }
      pgeff_tmpres_t *tmpres = lua_newuserdatauv(L, sizeof(pgeff_tmpres_t), 0);
      tmpres->pgres = pgres;
      luaL_setmetatable(L, PGEFF_TMPRES_MT_REGKEY);
      if (!lua_checkstack(L, 10)) { // TODO: use tighter bound?
        return luaL_error(L, "too many results for Lua stack");
      }
      luaL_setmetatable(L, PGEFF_TMPRES_MT_REGKEY);
      char *errmsg = PQresultErrorMessage(pgres);
      if (errmsg[0]) {
        lua_settop(L, 2);
        lua_pushnil(L); // 3
        lua_newtable(L); // 4
        pgeff_push_string_trim(L, errmsg);
        lua_setfield(L, -2, "message");
        char *sqlstate = PQresultErrorField(pgres, PG_DIAG_SQLSTATE);
        if (!sqlstate) sqlstate = "";
        pgeff_push_string_trim(L, sqlstate);
        lua_setfield(L, -2, "code");
        luaL_setmetatable(L, PGEFF_ERROR_MT_REGKEY);
        tmpres->pgres = NULL;
        PQclear(pgres);
        continue;
      }
      int rows = PQntuples(pgres);
      int cols = PQnfields(pgres);
      lua_newtable(L);
      lua_newtable(L);
      for (int col=0; col<cols; col++) {
        Oid type_oid = PQftype(pgres, col);
        lua_pushinteger(L, col+1);
        lua_pushinteger(L, type_oid);
        lua_settable(L, -3);
        lua_pushstring(L, PQfname(pgres, col));
        lua_pushinteger(L, type_oid);
        lua_settable(L, -3);
      }
      lua_setfield(L, -2, "type_oid");
      for (int row=0; row<rows; row++) {
        lua_pushinteger(L, row+1);
        lua_newtable(L);
        for (int col=0; col<cols; col++) {
          const char *value =
            PQgetisnull(pgres, row, col) ? NULL :
            PQgetvalue(pgres, row, col);
          if (value) {
            lua_pushinteger(L, col+1);
            Oid type_oid = PQftype(pgres, col);
            lua_geti(L, 2, type_oid);
            if (lua_isnil(L, -1)) {
              lua_pop(L, 1);
              switch (pgeff_sqltype(type_oid)) {
                case PGEFF_SQLTYPE_BOOL:
                  lua_pushboolean(L, value[0] == 't');
                  break;
                case PGEFF_SQLTYPE_INT:
                  if (!lua_stringtonumber(L, value)) {
                    lua_pushstring(L, value);
                  } else {
                    lua_pushinteger(L, lua_tointeger(L, -1));
                    lua_remove(L, -2);
                  }
                  break;
                case PGEFF_SQLTYPE_FLOAT:
                  if (!lua_stringtonumber(L, value)) {
                    lua_pushstring(L, value);
                  }
                  break;
                default:
                  lua_pushstring(L, value);
              }
            } else {
              lua_pushstring(L, value);
              lua_call(L, 1, 1);
            }
            lua_pushstring(L, PQfname(pgres, col));
            lua_pushvalue(L, -2);
            lua_settable(L, -5);
            lua_settable(L, -3);
          }
        }
        lua_settable(L, -3);
      }
      tmpres->pgres = NULL;
      PQclear(pgres);
      lua_remove(L, -2);
      luaL_setmetatable(L, PGEFF_RESULT_MT_REGKEY);
    }
    dbconn->query_waiting = 1;
    if (dbconn->listen_waiting) {
      lua_pushvalue(L, lua_upvalueindex(PGEFF_SELECT_UPVALIDX));
      lua_pushliteral(L, "handle");
      lua_getiuservalue(L, 1, PGEFF_DBCONN_QUERY_SLEEPER_USERVALIDX);
      lua_pushboolean(L, 0);
      lua_setfield(L, -2, "ready");
      lua_callk(L, 2, 0, ctx, pgeff_query_cont);
    } else {
      if (flushresult) {
        lua_pushvalue(L, lua_upvalueindex(PGEFF_SELECT_UPVALIDX));
        int fd = PQsocket(dbconn->pgconn);
        lua_pushliteral(L, "fd_read");
        lua_pushinteger(L, fd);
        lua_pushliteral(L, "fd_write");
        lua_pushinteger(L, fd);
        lua_pushliteral(L, "handle");
        lua_getiuservalue(L, 1, PGEFF_DBCONN_QUERY_SLEEPER_USERVALIDX);
        lua_pushboolean(L, 0);
        lua_setfield(L, -2, "ready");
        lua_callk(L, 6, 0, ctx, pgeff_query_cont);
      } else {
        lua_pushvalue(L, lua_upvalueindex(PGEFF_SELECT_UPVALIDX));
        lua_pushliteral(L, "fd_read");
        lua_pushinteger(L, PQsocket(dbconn->pgconn));
        lua_pushliteral(L, "handle");
        lua_getiuservalue(L, 1, PGEFF_DBCONN_QUERY_SLEEPER_USERVALIDX);
        lua_pushboolean(L, 0);
        lua_setfield(L, -2, "ready");
        lua_callk(L, 4, 0, ctx, pgeff_query_cont);
      }
    }
  }
}

static int pgeff_query(lua_State *L) {
  pgeff_dbconn_t *dbconn = luaL_checkudata(L, 1, PGEFF_DBCONN_MT_REGKEY);
  const char *querystring = luaL_checkstring(L, 2);
  int nparams = lua_gettop(L) - 2;
  if (!dbconn->pgconn) {
    return luaL_error(L, "database handle has been closed");
  }
  if (dbconn->query_waiting) return luaL_error(L,
    "cannot execute two queries concurrently on same database connection"
  );
  Oid *type_oids = lua_newuserdatauv(L, nparams * sizeof(Oid), 0);
  const char **values = lua_newuserdatauv(L, nparams * sizeof(char *), 0);
  lua_getfield(L, 1, "input_converter");
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_getfield(L,
      lua_upvalueindex(PGEFF_MODULE_UPVALIDX), "input_converter"
    );
  }
  int input_conversion = !lua_isnil(L, -1);
  for (int i=0; i<nparams; i++) {
    int j = i+3;
    if (input_conversion) {
      lua_pushvalue(L, -1);
      lua_pushvalue(L, j);
      lua_call(L, 1, 1);
      lua_replace(L, j);
    }
    switch (lua_type(L, j)) {
      case LUA_TBOOLEAN:
        type_oids[i] = PGEFF_OID_BOOL;
        values[i] = lua_toboolean(L, j) ? "t" : "f";
        break;
      default:
        if (input_conversion && !lua_isnil(L, j) && !lua_tostring(L, j)) {
          return luaL_error(L, "input converter did not return a string");
        }
        type_oids[i] = 0;
        values[i] = luaL_optstring(L, j, NULL);
    }
  }
  if (
    !PQsendQueryParams(
      dbconn->pgconn, querystring, nparams, type_oids, values, NULL, NULL, 0
    ) ||
    PQflush(dbconn->pgconn) < 0
  ) {
    lua_pushnil(L);
    lua_newtable(L);
    pgeff_push_string_trim(L, PQerrorMessage(dbconn->pgconn));
    lua_setfield(L, -2, "message");
    lua_pushliteral(L, "");
    lua_setfield(L, -2, "code");
    luaL_setmetatable(L, PGEFF_ERROR_MT_REGKEY);
    return 2;
  }
  lua_settop(L, 1);
  lua_getfield(L, 1, "output_converters"); // 2
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_getfield(L,
      lua_upvalueindex(PGEFF_MODULE_UPVALIDX), "output_converters"
    );
  }
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
  }
  return pgeff_query_cont(L, LUA_OK, (lua_KContext)dbconn);
}

static int pgeff_listen_cont(lua_State *L, int status, lua_KContext ctx) {
  pgeff_dbconn_t *dbconn = (pgeff_dbconn_t *)ctx;
  PGnotify *notify;
  while (1) {
    dbconn->listen_waiting = 0;
    if (!dbconn->pgconn) {
      return luaL_error(L, "database handle has been closed during query");
    }
    lua_getiuservalue(L, 1, PGEFF_DBCONN_QUERY_WAKER_USERVALIDX);
    lua_call(L, 0, 0);
    if (!PQconsumeInput(dbconn->pgconn)) {
      lua_pushnil(L);
      lua_newtable(L);
      pgeff_push_string_trim(L, PQerrorMessage(dbconn->pgconn));
      lua_setfield(L, -2, "message");
      lua_pushliteral(L, "");
      lua_setfield(L, -2, "code");
      luaL_setmetatable(L, PGEFF_ERROR_MT_REGKEY);
      return 2;
    }
    if ((notify = PQnotifies(dbconn->pgconn))) {
      pgeff_tmpnfy_t *tmpnfy = lua_newuserdatauv(L, sizeof(pgeff_tmpnfy_t), 0);
      tmpnfy->pgnfy = notify;
      luaL_setmetatable(L, PGEFF_TMPRES_MT_REGKEY);
      lua_createtable(L, 0, 3);
      lua_pushstring(L, notify->relname);
      lua_setfield(L, -2, "name");
      lua_pushinteger(L, notify->be_pid);
      lua_setfield(L, -2, "backend_pid");
      lua_pushstring(L, notify->extra);
      lua_setfield(L, -2, "payload");
      tmpnfy->pgnfy = NULL;
      PQfreemem(notify);
      return 1;
    }
    lua_pushvalue(L, lua_upvalueindex(PGEFF_SELECT_UPVALIDX));
    lua_pushliteral(L, "handle");
    lua_getiuservalue(L, 1, PGEFF_DBCONN_LISTEN_SLEEPER_USERVALIDX);
    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "ready");
    if (dbconn->query_waiting) {
      lua_callk(L, 2, 0, ctx, pgeff_listen_cont);
    } else {
      dbconn->listen_waiting = 1;
      lua_pushliteral(L, "fd_read");
      lua_pushinteger(L, PQsocket(dbconn->pgconn));
      lua_callk(L, 4, 0, ctx, pgeff_listen_cont);
    }
  }
}

static int pgeff_listen(lua_State *L) {
  pgeff_dbconn_t *dbconn = luaL_checkudata(L, 1, PGEFF_DBCONN_MT_REGKEY);
  if (!dbconn->pgconn) {
    return luaL_error(L, "database handle has been closed");
  }
  if (dbconn->listen_waiting) return luaL_error(L,
    "already listening for notifies on same database connection"
  );
  return pgeff_listen_cont(L, LUA_OK, (lua_KContext)dbconn);
}

static int pgeff_error_tostring(lua_State *L) {
  lua_getfield(L, 1, "message");
  return 1;
}

static const struct luaL_Reg pgeff_dbconn_methods[] = {
  {"close", pgeff_dbconn_close},
  {"query", pgeff_query},
  {"listen", pgeff_listen},
  {NULL, NULL}
};

static const struct luaL_Reg pgeff_dbconn_metamethods[] = {
  {"__close", pgeff_dbconn_close},
  // NOTE: closing requires deregister_fd, thus can't run through GC:
  //{"__gc", pgeff_dbconn_close},
  {"__index", pgeff_dbconn_index},
  {"__newindex", pgeff_dbconn_newindex},
  {NULL, NULL}
};

static const struct luaL_Reg pgeff_error_methods[] = {
  {NULL, NULL}
};

static const struct luaL_Reg pgeff_error_metamethods[] = {
  {"__tostring", pgeff_error_tostring},
  {NULL, NULL}
};

static const struct luaL_Reg pgeff_tmpres_metamethods[] = {
  {"__gc", pgeff_tmpres_gc},
  {NULL, NULL}
};

static const struct luaL_Reg pgeff_tmpnfy_metamethods[] = {
  {"__gc", pgeff_tmpnfy_gc},
  {NULL, NULL}
};

static const struct luaL_Reg pgeff_funcs[] = {
  {"connect", pgeff_connect},
  {NULL, NULL}
};

#define pgeff_userdata_helper() do { \
    lua_pushvalue(L, -5); \
    lua_pushvalue(L, -5); \
    lua_pushvalue(L, -5); \
    lua_pushvalue(L, -5); \
    lua_newtable(L); \
    lua_pushvalue(L, -5); \
    lua_pushvalue(L, -5); \
    lua_pushvalue(L, -5); \
    lua_pushvalue(L, -5); \
  } while (0)

// Library initialization:
int luaopen_neumond_pgeff(lua_State *L) {
  lua_settop(L, 0);

  luaL_newmetatable(L, PGEFF_TMPRES_MT_REGKEY); // 1
  luaL_setfuncs(L, pgeff_tmpres_metamethods, 0);
  lua_pop(L, 1); // 0

  luaL_newmetatable(L, PGEFF_TMPNFY_MT_REGKEY); // 1
  luaL_setfuncs(L, pgeff_tmpnfy_metamethods, 0);
  lua_pop(L, 1); // 0

  luaL_newlibtable(L, pgeff_funcs); // 1
  lua_pushvalue(L, -1); // 2
  lua_setfield(L, LUA_REGISTRYINDEX, PGEFF_MODULE_REGKEY); // 1
  lua_pushvalue(L, -1); // 2

  lua_getglobal(L, "require"); // 3
  lua_pushliteral(L, "neumond.wait"); // 4
  lua_call(L, 1, 1); // 3
  lua_getfield(L, -1, "notify"); // 4 -> 3
  lua_remove(L, -2);
  lua_getglobal(L, "require"); // 4
  lua_pushliteral(L, "neumond.wait_posix"); // 5
  lua_call(L, 1, 1); // 4
  lua_getfield(L, -1, "select"); // 5 -> 4
  lua_getfield(L, -2, "deregister_fd"); // 6 -> 5
  lua_remove(L, -3);

  luaL_newmetatable(L, PGEFF_DBCONN_MT_REGKEY); // 6
  pgeff_userdata_helper(); // 15
  luaL_setfuncs(L, pgeff_dbconn_methods, 4);
  luaL_setfuncs(L, pgeff_dbconn_metamethods, 5);
  lua_setfield(L, 1, "dbconn_mt"); // 5

  luaL_newmetatable(L, PGEFF_RESULT_MT_REGKEY); // 6
  lua_setfield(L, 1, "result_mt"); // 5

  luaL_newmetatable(L, PGEFF_ERROR_MT_REGKEY); // 6
  pgeff_userdata_helper(); // 15
  luaL_setfuncs(L, pgeff_error_methods, 4);
  luaL_setfuncs(L, pgeff_error_metamethods, 5);
  lua_setfield(L, 1, "error_mt"); // 5

  luaL_setfuncs(L, pgeff_funcs, 4);
  return 1;
}
