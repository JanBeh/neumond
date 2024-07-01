#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>
#include <libpq-fe.h>

// NOTE: only needed for notice processor:
#define PGEFF_MODULE_REGKEY "pgeff_module"

#define PGEFF_DBCONN_MT_REGKEY "pgeff_dbconn"
#define PGEFF_TMPRES_MT_REGKEY "pgeff_tmpres"
#define PGEFF_RESULT_MT_REGKEY "pgeff_result"
#define PGEFF_ERROR_MT_REGKEY "pgeff_error"

#define PGEFF_MODULE_UPVALIDX 1
#define PGEFF_SELECT_UPVALIDX 2
#define PGEFF_DEREGISTER_FD_UPVALIDX 3

#define PGEFF_METHODS_UPVALIDX 4

#define PGEFF_DBCONN_ATTR_USERVALIDX 1
#define PGEFF_DBCONN_USERVAL_COUNT 1

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
} pgeff_dbconn_t;

typedef struct {
  PGresult *pgres;
} pgeff_tmpres_t;

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
  // luaL_checkudata not necessary as userdata value is never exposed to user:
  //pgeff_tmpres_t *tmpres = luaL_checkudata(L, 1, PGEFF_RESULT_MT_REGKEY);
  pgeff_tmpres_t *tmpres = lua_touserdata(L, 1);
  if (tmpres->pgres) {
    PQclear(tmpres->pgres);
    // setting to NULL not necessary as __gc metamethod is only called once:
    //tmpres->pgres = NULL;
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
  luaL_setmetatable(L, PGEFF_DBCONN_MT_REGKEY);
  PQsetNoticeProcessor(dbconn->pgconn, pgeff_notice_processor, L);
  return pgeff_connect_cont(L, LUA_OK, (lua_KContext)dbconn);
}

static int pgeff_query_cont(lua_State *L, int status, lua_KContext ctx) {
  pgeff_dbconn_t *dbconn = (pgeff_dbconn_t *)ctx;
  while (1) {
    if (!dbconn->pgconn) {
      return luaL_error(L, "database handle has been closed during query");
    }
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
      pgeff_tmpres_t *tmpres = lua_newuserdatauv(L, sizeof(pgeff_tmpres_t), 0);
      PGresult *pgres = PQgetResult(dbconn->pgconn);
      if (!pgres) return lua_gettop(L) - 2;
      if (lua_type(L, 3) == LUA_TNIL) {
        PQclear(pgres);
        continue;
      }
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
    if (flushresult) {
      lua_pushvalue(L, lua_upvalueindex(PGEFF_SELECT_UPVALIDX));
      int fd = PQsocket(dbconn->pgconn);
      lua_pushliteral(L, "fd_read");
      lua_pushinteger(L, fd);
      lua_pushliteral(L, "fd_write");
      lua_pushinteger(L, fd);
      lua_callk(L, 4, 0, ctx, pgeff_query_cont);
    } else {
      lua_pushvalue(L, lua_upvalueindex(PGEFF_SELECT_UPVALIDX));
      lua_pushliteral(L, "fd_read");
      lua_pushinteger(L, PQsocket(dbconn->pgconn));
      lua_callk(L, 2, 0, ctx, pgeff_query_cont);
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

static const struct luaL_Reg pgeff_funcs[] = {
  {"connect", pgeff_connect},
  {NULL, NULL}
};

#define pgeff_userdata_helper() do { \
    lua_pushvalue(L, -4); \
    lua_pushvalue(L, -4); \
    lua_pushvalue(L, -4); \
    lua_newtable(L); \
    lua_pushvalue(L, -4); \
    lua_pushvalue(L, -4); \
    lua_pushvalue(L, -4); \
  } while (0)

// Library initialization:
int luaopen_neumond_pgeff(lua_State *L) {
  lua_settop(L, 0);

  luaL_newmetatable(L, PGEFF_TMPRES_MT_REGKEY); // 1
  luaL_setfuncs(L, pgeff_tmpres_metamethods, 0);
  lua_pop(L, 1); // 0

  luaL_newlibtable(L, pgeff_funcs); // 1
  lua_pushvalue(L, -1); // 2
  lua_setfield(L, LUA_REGISTRYINDEX, PGEFF_MODULE_REGKEY); // 1
  lua_pushvalue(L, -1); // 2

  lua_getglobal(L, "require"); // 3
  lua_pushliteral(L, "neumond.wait_posix"); // 4
  lua_call(L, 1, 1); // 3
  lua_getfield(L, -1, "select"); // 4 -> 3
  lua_getfield(L, -1, "deregister_fd"); // 5 -> 4
  lua_remove(L, -3);

  luaL_newmetatable(L, PGEFF_DBCONN_MT_REGKEY); // 5
  pgeff_userdata_helper(); // 12
  luaL_setfuncs(L, pgeff_dbconn_methods, 3);
  luaL_setfuncs(L, pgeff_dbconn_metamethods, 4);
  lua_setfield(L, 1, "dbconn_mt"); // 4

  luaL_newmetatable(L, PGEFF_RESULT_MT_REGKEY); // 5
  lua_setfield(L, 1, "result_mt"); // 4

  luaL_newmetatable(L, PGEFF_ERROR_MT_REGKEY); // 5
  pgeff_userdata_helper(); // 12
  luaL_setfuncs(L, pgeff_error_methods, 3);
  luaL_setfuncs(L, pgeff_error_metamethods, 4);
  lua_setfield(L, 1, "error_mt"); // 4

  luaL_setfuncs(L, pgeff_funcs, 3);
  return 1;
}
