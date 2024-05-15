#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>
#include <libpq-fe.h>

#define PGEFF_DBCONN_MT_REGKEY "pgeff_dbconn"
#define PGEFF_DEFERRED_MT_REGKEY "pgeff_deferred"
#define PGEFF_ERROR_MT_REGKEY "pgeff_error"
#define PGEFF_RESULT_MT_REGKEY "pgeff_result"

#define PGEFF_MODULE_UPVALIDX 1
#define PGEFF_SELECT_UPVALIDX 2
#define PGEFF_DEREGISTER_FD_UPVALIDX 3
#define PGEFF_SYNC_UPVALIDX 4

#define PGEFF_METHODS_UPVALIDX 5

#define PGEFF_DBCONN_ATTR_USERVALIDX 1
#define PGEFF_DBCONN_DEFERRED_FIRST_USERVALIDX 2
#define PGEFF_DBCONN_DEFERRED_LAST_USERVALIDX 3
#define PGEFF_DBCONN_USERVAL_COUNT 3

#define PGEFF_DEFERRED_DBCONN_USERVALIDX 1
#define PGEFF_DEFERRED_NEXT_USERVALIDX 2
#define PGEFF_DEFERRED_WAKER_USERVALIDX 3
#define PGEFF_DEFERRED_RESULT_USERVALIDX 4
#define PGEFF_DEFERRED_USERVAL_COUNT 4

#define PGEFF_STATE_QUEUED 0
#define PGEFF_STATE_READY 1
#define PGEFF_STATE_READ 2

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
  int error;
} pgeff_dbconn_t;

typedef struct {
  int state;
} pgeff_deferred_t;

typedef struct {
  PGresult *pgres;
} pgeff_result_t;

static void pgeff_push_string_trim(lua_State *L, const char *s) {
  size_t len = strlen(s);
  if (s[len-1] == '\n') len--;
  lua_pushlstring(L, s, len);
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

static int pgeff_result_gc(lua_State *L) {
  // luaL_checkudata not necessary as userdata value is never exposed to user:
  //pgeff_result_t *result = luaL_checkudata(L, 1, PGEFF_RESULT_MT_REGKEY);
  pgeff_result_t *result = lua_touserdata(L, 1);
  if (result->pgres) {
    PQclear(result->pgres);
    // setting to NULL not necessary as __gc metamethod is only called once:
    //result->pgres = NULL;
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
        if (PQenterPipelineMode(dbconn->pgconn) != 1) {
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
  dbconn->error = 0;
  luaL_setmetatable(L, PGEFF_DBCONN_MT_REGKEY);
  return pgeff_connect_cont(L, LUA_OK, (lua_KContext)dbconn);
}

static int pgeff_query(lua_State *L) {
  pgeff_dbconn_t *dbconn = luaL_checkudata(L, 1, PGEFF_DBCONN_MT_REGKEY);
  const char *querystring = luaL_checkstring(L, 2);
  int nparams = lua_gettop(L) - 2;
  if (!dbconn->pgconn) {
    return luaL_error(L, "database handle has been closed");
  }
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
    !PQsendFlushRequest(dbconn->pgconn) ||
    PQflush(dbconn->pgconn) < 0
  ) {
    lua_pushnil(L);
    pgeff_push_string_trim(L, PQerrorMessage(dbconn->pgconn));
    return 2;
  }
  lua_settop(L, 1);
  pgeff_deferred_t *deferred = lua_newuserdatauv(L,
    sizeof(pgeff_deferred_t), PGEFF_DEFERRED_USERVAL_COUNT
  ); // 2
  deferred->state = PGEFF_STATE_QUEUED;
  luaL_setmetatable(L, PGEFF_DEFERRED_MT_REGKEY);
  lua_pushvalue(L, 1);
  lua_setiuservalue(L, 2, PGEFF_DEFERRED_DBCONN_USERVALIDX);
  lua_getiuservalue(L, 1, PGEFF_DBCONN_DEFERRED_LAST_USERVALIDX); // 3
  lua_pushvalue(L, 2);
  if (lua_isnil(L, 3)) {
    lua_setiuservalue(L, 1, PGEFF_DBCONN_DEFERRED_FIRST_USERVALIDX);
    deferred->state = PGEFF_STATE_READY;
  } else {
    lua_setiuservalue(L, 3, PGEFF_DEFERRED_NEXT_USERVALIDX);
  }
  lua_pushvalue(L, 2);
  lua_setiuservalue(L, 1, PGEFF_DBCONN_DEFERRED_LAST_USERVALIDX);
  lua_settop(L, 2);
  return 1;
}

static int pgeff_deferred_await_finish(
  lua_State *L, int status, lua_KContext ctx
) {
  return lua_gettop(L) - 3;
}

static int pgeff_deferred_await_fail(
  lua_State *L, int status, lua_KContext ctx
) {
  return 2;
}

static int pgeff_deferred_await_cont(
  lua_State *L, int status, lua_KContext ctx
) {
  //pgeff_deferred_t *deferred = lua_touserdata(L, 1);
  pgeff_dbconn_t *dbconn = (pgeff_dbconn_t *)ctx;
  while (1) {
    if (!dbconn->pgconn) {
      return luaL_error(L, "database handle has been closed during query");
    }
    int flushresult;
    if (
      dbconn->error ||
      !PQconsumeInput(dbconn->pgconn) ||
      (flushresult = PQflush(dbconn->pgconn), flushresult < 0)
    ) {
      dbconn->error = 1;
      lua_pushnil(L);
      lua_newtable(L);
      if (dbconn->error) {
        lua_pushliteral(L, "database connection in error state");
      } else {
        pgeff_push_string_trim(L, PQerrorMessage(dbconn->pgconn));
      }
      lua_setfield(L, -2, "message");
      lua_pushliteral(L, "");
      lua_setfield(L, -2, "code");
      luaL_setmetatable(L, PGEFF_ERROR_MT_REGKEY);
      lua_getiuservalue(L, 1, PGEFF_DEFERRED_NEXT_USERVALIDX);
      if (lua_isnil(L, -1)) {
        lua_pushnil(L);
        lua_setiuservalue(L, 2, PGEFF_DBCONN_DEFERRED_LAST_USERVALIDX);
        lua_setiuservalue(L, 2, PGEFF_DBCONN_DEFERRED_FIRST_USERVALIDX);
      } else {
        lua_getiuservalue(L, -1, PGEFF_DEFERRED_WAKER_USERVALIDX);
        lua_insert(L, -2);
        ((pgeff_deferred_t *)(lua_touserdata(L, -1)))->state =
          PGEFF_STATE_READY;
        lua_setiuservalue(L, 2, PGEFF_DBCONN_DEFERRED_FIRST_USERVALIDX);
        if (lua_isnil(L, -1)) lua_pop(L, 1);
        else lua_callk(L, 0, 0, (lua_KContext)0, pgeff_deferred_await_fail);
      }
      return pgeff_deferred_await_fail(L, LUA_OK, (lua_KContext)0);
    }
    while (!PQisBusy(dbconn->pgconn)) {
      pgeff_result_t *result = NULL;
      if (lua_type(L, 4) != LUA_TNIL) {
      }
      PGresult *pgres = PQgetResult(dbconn->pgconn);
      if (!pgres) {
        lua_pushvalue(L, 4);
        lua_setiuservalue(L, 1, PGEFF_DEFERRED_RESULT_USERVALIDX);
        lua_getiuservalue(L, 1, PGEFF_DEFERRED_NEXT_USERVALIDX);
        if (lua_isnil(L, -1)) {
          lua_pushnil(L);
          lua_setiuservalue(L, 2, PGEFF_DBCONN_DEFERRED_LAST_USERVALIDX);
          lua_setiuservalue(L, 2, PGEFF_DBCONN_DEFERRED_FIRST_USERVALIDX);
        } else {
          lua_getiuservalue(L, -1, PGEFF_DEFERRED_WAKER_USERVALIDX);
          lua_insert(L, -2);
          ((pgeff_deferred_t *)(lua_touserdata(L, -1)))->state =
            PGEFF_STATE_READY;
          lua_setiuservalue(L, 2, PGEFF_DBCONN_DEFERRED_FIRST_USERVALIDX);
          if (lua_isnil(L, -1)) lua_pop(L, 1);
          else lua_callk(L,
            0, 0, (lua_KContext)0, pgeff_deferred_await_finish
          );
        }
        return pgeff_deferred_await_finish(L, LUA_OK, (lua_KContext)0);
      }
      if (lua_type(L, 4) == LUA_TNIL) {
        PQclear(pgres);
        goto pgeff_deferred_await_skip;
      }
      if (!lua_checkstack(L, 10)) { // TODO: use tighter bound?
        return luaL_error(L, "too many results for Lua stack");
      }
      result = lua_newuserdatauv(L, sizeof(pgeff_result_t), 0);
      result->pgres = pgres;
      luaL_setmetatable(L, PGEFF_RESULT_MT_REGKEY);
      char *errmsg = PQresultErrorMessage(pgres);
      if (errmsg[0] || PQresultStatus(pgres) == PGRES_PIPELINE_ABORTED) {
        lua_settop(L, 3);
        lua_pushnil(L);
        lua_newtable(L);
        if (errmsg[0]) pgeff_push_string_trim(L, errmsg);
        else lua_pushliteral(L, "pipeline aborted");
        lua_setfield(L, -2, "message");
        char *sqlstate = PQresultErrorField(pgres, PG_DIAG_SQLSTATE);
        if (!sqlstate) sqlstate = "";
        pgeff_push_string_trim(L, sqlstate);
        lua_setfield(L, -2, "code");
        luaL_setmetatable(L, PGEFF_ERROR_MT_REGKEY);
        result->pgres = NULL;
        PQclear(pgres);
        goto pgeff_deferred_await_skip;
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
            lua_geti(L, 3, type_oid);
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
      result->pgres = NULL;
      PQclear(pgres);
      lua_remove(L, -2);
      pgeff_deferred_await_skip:;
    }
    if (flushresult) {
      lua_pushvalue(L, lua_upvalueindex(PGEFF_SELECT_UPVALIDX));
      int fd = PQsocket(dbconn->pgconn);
      lua_pushliteral(L, "fd_read");
      lua_pushinteger(L, fd);
      lua_pushliteral(L, "fd_write");
      lua_pushinteger(L, fd);
      lua_callk(L, 4, 0, ctx, pgeff_deferred_await_cont);
    } else {
      lua_pushvalue(L, lua_upvalueindex(PGEFF_SELECT_UPVALIDX));
      lua_pushliteral(L, "fd_read");
      lua_pushinteger(L, PQsocket(dbconn->pgconn));
      lua_callk(L, 2, 0, ctx, pgeff_deferred_await_cont);
    }
  }
}

static int pgeff_deferred_await_use_sleeper(
  lua_State *L, int status, lua_KContext ctx
) {
  lua_setiuservalue(L, 1, PGEFF_DEFERRED_WAKER_USERVALIDX);
  lua_callk(L, 0, 0, ctx, pgeff_deferred_await_cont);
  return pgeff_deferred_await_cont(L, LUA_OK, ctx);
}

static int pgeff_deferred_await(lua_State *L) {
  pgeff_deferred_t *deferred = luaL_checkudata(L, 1, PGEFF_DEFERRED_MT_REGKEY);
  if (deferred->state == PGEFF_STATE_READ) {
    return luaL_error(L, "cannot await database result multiple times");
  }
  lua_settop(L, 1);
  lua_getiuservalue(L, 1, PGEFF_DEFERRED_DBCONN_USERVALIDX); // 2
  pgeff_dbconn_t *dbconn = lua_touserdata(L, 2);
  lua_getfield(L, 2, "output_converters"); // 3
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
  if (deferred->state == PGEFF_STATE_QUEUED) {
    deferred->state = PGEFF_STATE_READ;
    lua_pushvalue(L, lua_upvalueindex(PGEFF_SYNC_UPVALIDX));
    lua_callk(L, 0, 2, (lua_KContext)dbconn, pgeff_deferred_await_use_sleeper);
    return pgeff_deferred_await_use_sleeper(L, LUA_OK, (lua_KContext)dbconn);
  } else {
    deferred->state = PGEFF_STATE_READ;
    return pgeff_deferred_await_cont(L, LUA_OK, (lua_KContext)dbconn);
  }
}

static int pgeff_deferred_index_cont(
  lua_State *L, int status, lua_KContext ctx
) {
  if (lua_isnil(L, 3)) lua_error(L);
  lua_pushvalue(L, 2);
  lua_rawget(L, 3);
  if (!lua_isnil(L, -1)) return 1;
  lua_settop(L, 2);
  lua_rawget(L, lua_upvalueindex(PGEFF_METHODS_UPVALIDX));
  return 1;
}

static int pgeff_deferred_index(lua_State *L) {
  luaL_checkudata(L, 1, PGEFF_DEFERRED_MT_REGKEY);
  lua_settop(L, 2);
  lua_getiuservalue(L, 1, PGEFF_DEFERRED_RESULT_USERVALIDX);
  if (lua_isnil(L, -1)) {
    lua_settop(L, 2);
    lua_pushvalue(L, 1);
    lua_callk(L, 0, 2, (lua_KContext)0, pgeff_deferred_index_cont);
  }
  return pgeff_deferred_index_cont(L, LUA_OK, (lua_KContext)0);
}

static int pgeff_error_tostring(lua_State *L) {
  lua_getfield(L, 1, "message");
  return 1;
}

static const struct luaL_Reg pgeff_dbconn_methods[] = {
  {"close", pgeff_dbconn_close},
  {"query", pgeff_query},
  {NULL, NULL}
};

static const struct luaL_Reg pgeff_dbconn_metamethods[] = {
  {"__close", pgeff_dbconn_close},
  {"__gc", pgeff_dbconn_close},
  {"__index", pgeff_dbconn_index},
  {"__newindex", pgeff_dbconn_newindex},
  {NULL, NULL}
};

static const struct luaL_Reg pgeff_deferred_methods[] = {
  {NULL, NULL}
};

static const struct luaL_Reg pgeff_deferred_metamethods[] = {
  {"__call", pgeff_deferred_await},
  {"__index", pgeff_deferred_index},
  {NULL, NULL}
};

static const struct luaL_Reg pgeff_error_methods[] = {
  {NULL, NULL}
};

static const struct luaL_Reg pgeff_error_metamethods[] = {
  {"__tostring", pgeff_error_tostring},
  {NULL, NULL}
};

static const struct luaL_Reg pgeff_result_metamethods[] = {
  {"__gc", pgeff_result_gc},
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
int luaopen_pgeff(lua_State *L) {

  luaL_newmetatable(L, PGEFF_RESULT_MT_REGKEY);
  luaL_setfuncs(L, pgeff_result_metamethods, 0);
  lua_pop(L, 1);

  luaL_newlibtable(L, pgeff_funcs);
  lua_pushvalue(L, -1);

  lua_getglobal(L, "require");
  lua_pushliteral(L, "waitio");
  lua_call(L, 1, 1);
  lua_getfield(L, -1, "select");
  lua_getfield(L, -2, "deregister_fd");
  lua_getfield(L, -3, "sync");
  lua_remove(L, -4);

  luaL_newmetatable(L, PGEFF_DBCONN_MT_REGKEY);
  pgeff_userdata_helper();
  luaL_setfuncs(L, pgeff_dbconn_methods, 4);
  luaL_setfuncs(L, pgeff_dbconn_metamethods, 5);
  lua_pop(L, 1);

  luaL_newmetatable(L, PGEFF_DEFERRED_MT_REGKEY);
  pgeff_userdata_helper();
  luaL_setfuncs(L, pgeff_deferred_methods, 4);
  luaL_setfuncs(L, pgeff_deferred_metamethods, 5);
  lua_pop(L, 1);

  luaL_newmetatable(L, PGEFF_ERROR_MT_REGKEY);
  pgeff_userdata_helper();
  luaL_setfuncs(L, pgeff_error_methods, 4);
  luaL_setfuncs(L, pgeff_error_metamethods, 5);
  lua_pop(L, 1);

  luaL_setfuncs(L, pgeff_funcs, 4);
  return 1;
}
