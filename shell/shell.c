/*
 * shell.c - AniDB command intepreter
 * Copyright (C) 2014 twoion <dev@2ion.de>
 * The GNU GPL v3 applies.
 */
#include <assert.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <readline/readline.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

/* types */

typedef int ref_t;
typedef int func_t;

typedef struct {
  lua_State *L;
  const char *api_path;
  ref_t api; // api method table
  ref_t api_func_init;
  ref_t api_func_exit;
  ref_t api_func_search;
  ref_t api_func_info;
} _G;

/* globals */

static _G G, dG = {
  .api_path = "../api/http.lua"
};

static const int API_INDEX = -1; // api table will always be on top

enum { CLEANUP_PROPERLY, CLEANUP_DIRTY };

/* prototypes */

static int apicall(const char *func, ...);
static int cleanup(int exitcode, int path);
static void init(void);

/* functions */

static int apicall(const char *func, ...) {
  assert(func);

  va_list ap;
  int argc;

  lua_getfield(G.L, API_INDEX, func);

  va_start(ap, func);
  /* stack loop */
  va_end(ap);

  return 0;
}

static void init(void) {
  if((G.api_path = getenv("ANIDBSH_APIPATH")) == NULL)
    G.api_path = dG.api_path;
  G.L = luaL_newstate();
  if(luaL_dofile(G.L, G.api_path) == 0) {
    fprintf(stderr, "Failed to load API library from %s\n", G.api_path);
    exit(cleanup(EXIT_FAILURE, CLEANUP_DIRTY));
  }
  if((G.api = luaL_ref(G.L, LUA_REGISTRYINDEX)) == LUA_REFNIL) {
    fprintf(stderr, "Failure: API library didn't return an object\n");
    exit(cleanup(EXIT_FAILURE, CLEANUP_DIRTY));
  }
}

static int cleanup(int exitcode, int path) {
  switch(path) {
  CLEANUP_PROPERLY:
    luaL_unref(G.L, LUA_REGISTRYINDEX, G.api);
  CLEANUP_DIRTY:
    lua_close(G.L);
  }
  return exitcode;
}

int main(int argc, char*argv[]) {
  init();
  return cleanup(EXIT_SUCCESS, CLEANUP_PROPERLY);
}

