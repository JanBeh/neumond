#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>
#include <libpq-fe.h>

#define PGEFF_DBCONN_MT_REGKEY "pgeff_dbconn"
#define PGEFF_RESULT_MT_REGKEY "pgeff_result"

#define PGEFF_SELECT_UPVALIDX 1
#define PGEFF_DEREGISTER_FD_UPVALIDX 2

#define PGEFF_DBCONN_METHODS_UPVALIDX 3

#define PGEFF_STATE_IDLE 0
#define PGEFF_STATE_FLUSHING 1
#define PGEFF_STATE_CONSUMING 2

typedef struct {
  PGconn *pgconn;
  int fd;
  int state;
} pgeff_dbconn_t;

typedef struct {
  PGresult *pgres;
} pgeff_result_t;

static void pgeff_push_string_trim(lua_State *L, const char *s) {
  size_t len = strlen(s);
  while (s[len-1] == '\n') len--;
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
  if (dbconn->fd != -1) {
    int fd = dbconn->fd;
    dbconn->fd = -1;
    lua_pushvalue(L, lua_upvalueindex(PGEFF_DEREGISTER_FD_UPVALIDX));
    lua_pushinteger(L, fd);
    lua_callk(L, 1, 0, (lua_KContext)dbconn, pgeff_dbconn_close_cont);
  }
  return pgeff_dbconn_close_cont(L, LUA_OK, (lua_KContext)dbconn);
}

static int pgeff_result_close(lua_State *L) {
  pgeff_result_t *result = luaL_checkudata(L, 1, PGEFF_RESULT_MT_REGKEY);
  if (result->pgres) {
    PQclear(result->pgres);
    result->pgres = NULL;
  }
  return 0;
}

static int pgeff_dbconn_index(lua_State *L) {
  //pgeff_dbconn_t *dbconn = luaL_checkudata(L, 1, PGEFF_DBCONN_MT_REGKEY);
  lua_settop(L, 2);
  lua_gettable(L, lua_upvalueindex(PGEFF_DBCONN_METHODS_UPVALIDX));
  return 1;
}

static int pgeff_connect_cont(lua_State *L, int status, lua_KContext ctx) {
  pgeff_dbconn_t *dbconn = (pgeff_dbconn_t *)ctx;
  while (1) {
    dbconn->fd = -1;
    switch (PQconnectPoll(dbconn->pgconn)) {
      case PGRES_POLLING_OK:
        if (PQsetnonblocking(dbconn->pgconn, 1)) {
          lua_pushnil(L);
          pgeff_push_string_trim(L, PQerrorMessage(dbconn->pgconn));
          return 2;
        }
        return 1;
      case PGRES_POLLING_READING:
        dbconn->fd = PQsocket(dbconn->pgconn);
        lua_pushvalue(L, lua_upvalueindex(PGEFF_SELECT_UPVALIDX));
        lua_pushliteral(L, "fd_read");
        lua_pushinteger(L, dbconn->fd);
        lua_callk(L, 2, 0, ctx, pgeff_connect_cont);
        break;
      case PGRES_POLLING_WRITING:
        dbconn->fd = PQsocket(dbconn->pgconn);
        lua_pushvalue(L, lua_upvalueindex(PGEFF_SELECT_UPVALIDX));
        lua_pushliteral(L, "fd_write");
        lua_pushinteger(L, dbconn->fd);
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
  pgeff_dbconn_t *dbconn = lua_newuserdatauv(L, sizeof(pgeff_dbconn_t), 0);
  dbconn->fd = -1;
  dbconn->state = PGEFF_STATE_IDLE;
  dbconn->pgconn = PQconnectStart(conninfo);
  luaL_setmetatable(L, PGEFF_DBCONN_MT_REGKEY);
  if (!dbconn->pgconn) return luaL_error(L,
    "could not allocate memory for PGconn structure"
  );
  pgeff_connect_cont(L, LUA_OK, (lua_KContext)dbconn);
  return 0;
}

static int pgeff_query_cont(lua_State *L, int status, lua_KContext ctx) {
  pgeff_dbconn_t *dbconn = (pgeff_dbconn_t *)ctx;
  while (1) {
    dbconn->fd = -1;
    if (!dbconn->pgconn) {
      return luaL_error(L, "database handle has been closed during query");
    }
    if (!PQconsumeInput(dbconn->pgconn)) {
      lua_pushnil(L);
      pgeff_push_string_trim(L, PQerrorMessage(dbconn->pgconn));
      return 2;
    }
    switch (dbconn->state) {
      case PGEFF_STATE_FLUSHING:
        switch (PQflush(dbconn->pgconn)) {
          case 0:
            dbconn->state = PGEFF_STATE_CONSUMING;
            break;
          case 1:
            break;
          case -1:
            lua_pushnil(L);
            pgeff_push_string_trim(L, PQerrorMessage(dbconn->pgconn));
            return 2;
          default: abort();
        }
        break;
      case PGEFF_STATE_CONSUMING:
        while (!PQisBusy(dbconn->pgconn)) {
          PGresult *pgres = PQgetResult(dbconn->pgconn);
          if (!pgres) {
            dbconn->state = PGEFF_STATE_IDLE;
            return lua_gettop(L) - 2;
          }
          if (!lua_checkstack(L, 1)) {
            return luaL_error(L, "too many results for Lua stack");
          }
          pgeff_result_t *result = lua_newuserdatauv(
            L, sizeof(pgeff_result_t), 0
          );
          result->pgres = pgres;
          luaL_setmetatable(L, PGEFF_RESULT_MT_REGKEY);
          lua_newtable(L);
          char *errmsg = PQresultErrorMessage(pgres);
          if (errmsg[0]) {
            pgeff_push_string_trim(L, errmsg);
            lua_setfield(L, -2, "error_message");
            char *sqlstate = PQresultErrorField(pgres, PG_DIAG_SQLSTATE);
            if (!sqlstate) sqlstate = "";
            pgeff_push_string_trim(L, sqlstate);
            lua_setfield(L, -2, "error_code");
          }
          int rows = PQntuples(pgres);
          int cols = PQnfields(pgres);
          for (int row=0; row<rows; row++) {
            lua_pushinteger(L, row+1);
            lua_newtable(L);
            for (int col=0; col<cols; col++) {
              const char *value = PQgetvalue(pgres, row, col);
              lua_pushinteger(L, col+1);
              lua_pushstring(L, value);
              lua_settable(L, -3);
              lua_pushstring(L, PQfname(pgres, col));
              lua_pushstring(L, value);
              lua_settable(L, -3);
            }
            lua_settable(L, -3);
          }
          result->pgres = NULL;
          PQclear(pgres);
          lua_remove(L, -2);
        }
        break;
      default: abort();
    }
    dbconn->fd = PQsocket(dbconn->pgconn);
    switch (dbconn->state) {
      case PGEFF_STATE_FLUSHING:
        lua_pushvalue(L, lua_upvalueindex(PGEFF_SELECT_UPVALIDX));
        lua_pushliteral(L, "fd_read");
        lua_pushinteger(L, dbconn->fd);
        lua_pushliteral(L, "fd_write");
        lua_pushinteger(L, dbconn->fd);
        lua_callk(L, 4, 0, ctx, pgeff_query_cont);
        break;
      case PGEFF_STATE_CONSUMING:
        lua_pushvalue(L, lua_upvalueindex(PGEFF_SELECT_UPVALIDX));
        lua_pushliteral(L, "fd_read");
        lua_pushinteger(L, dbconn->fd);
        lua_callk(L, 2, 0, ctx, pgeff_query_cont);
        break;
      default: abort();
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
  if (dbconn->state != PGEFF_STATE_IDLE) {
    return luaL_error(L, "database handle is in use");
  }
  const char **values = lua_newuserdatauv(L, nparams * sizeof(char *), 0);
  for (int i=0; i<nparams; i++) {
    values[i] = luaL_tolstring(L, i+3, NULL);
  }
  if (!PQsendQueryParams(
    dbconn->pgconn, querystring, nparams, NULL, values, NULL, NULL, 0
  )) {
    lua_pushnil(L);
    pgeff_push_string_trim(L, PQerrorMessage(dbconn->pgconn));
    return 2;
  }
  lua_settop(L, 2);
  dbconn->state = PGEFF_STATE_FLUSHING;
  pgeff_query_cont(L, LUA_OK, (lua_KContext)dbconn);
  return 0;
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
  {NULL, NULL}
};

static const struct luaL_Reg pgeff_result_metamethods[] = {
  {"__gc", pgeff_result_close},
  {NULL, NULL}
};

static const struct luaL_Reg pgeff_funcs[] = {
  {"connect", pgeff_connect},
  {NULL, NULL}
};

// Library initialization:
int luaopen_pgeff(lua_State *L) {
  lua_getglobal(L, "require");
  lua_pushliteral(L, "waitio");
  lua_call(L, 1, 1);
  lua_getfield(L, -1, "select");
  lua_getfield(L, -2, "deregister_fd");
  lua_remove(L, -3);

  luaL_newmetatable(L, PGEFF_DBCONN_MT_REGKEY);
  lua_newtable(L);
  lua_pushvalue(L, -4);
  lua_pushvalue(L, -4);
  lua_pushvalue(L, -2);
  lua_pushvalue(L, -2);
  luaL_setfuncs(L, pgeff_dbconn_methods, 2);
  luaL_setfuncs(L, pgeff_dbconn_metamethods, 3);
  lua_pop(L, 1);

  luaL_newmetatable(L, PGEFF_RESULT_MT_REGKEY);
  luaL_setfuncs(L, pgeff_result_metamethods, 0);
  lua_pop(L, 1);

  luaL_newlibtable(L, pgeff_funcs);
  lua_pushvalue(L, -3);
  lua_pushvalue(L, -3);
  luaL_setfuncs(L, pgeff_funcs, 2);
  return 1;
}
