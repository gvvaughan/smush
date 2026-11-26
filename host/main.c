/*
 * Smush the source, Luke!
 * Copyright (C) 2026 Gary V. Vaughan
 *
 * The program of a standalone build: Lua, with the Lua of the program
 * compiled in as the data of a barf, and run from there.
 *
 * It is linked with Lua and the file that the build supplies:
 *
 *     data.c     runtime_data and runtime_size, the bytes of an indexed
 *                barf (see lib/smush/barf.lua), which `embed runtime`
 *                of crush writes.  Its paths are those of the Lua files
 *                of the program, such as `std/normalize/init.lua`.
 *
 * A program that has C modules also defines HOST_MODULES, and links a
 * file that defines host_modules, the modules as a list of luaL_Reg
 * ended by {NULL, NULL}.  A program that has none needs neither.
 *
 * The program runs `main.lua` from the barf, with its arguments, and
 * with them in the table `arg` too.  Its modules are loaded from the
 * barf, each when it is first required, which is when it is compiled.
 * `require` finds a module in host_modules, or else in the barf: the
 * Lua path and the C path are not used, so a module that is not in
 * the program is an error, and is never one that happens to be on the
 * machine.  The module `smush.payload` is always there, and its
 * read(path) is the bytes of the file `path` of the barf, or nil if
 * there is none.
 *
 * It builds with Lua 5.1 to 5.5 and LuaJIT, whichever the build links
 * with, and runs the Lua of the program in that.
 */

#define BARFX_LIBRARY
#include "barfx.c"

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

/* What Lua 5.1 and LuaJIT lack, as it is in 5.2 and later. */
#if LUA_VERSION_NUM < 502
#define LUA_OK 0
#define luaL_len(L, i) ((lua_Integer) lua_objlen(L, i))
#define SEARCHERS "loaders"
#else
#define SEARCHERS "searchers"
#endif

/* A searcher gives require what it did not find as a message.  Lua 5.4
   puts a newline and a tab before each, and the others expect each
   message to have them. */
#if LUA_VERSION_NUM < 504
#define NOT_FOUND "\n\t"
#else
#define NOT_FOUND ""
#endif

extern const unsigned char runtime_data[];
extern const unsigned long runtime_size;
#ifdef HOST_MODULES
extern const luaL_Reg host_modules[];
#endif


/* The name of the program, for what it reports. */
static const char *progname = "program";

/* The data of the entries of the barf, where the offsets of the index
   start, and how many bytes are there. */
static const unsigned char *payload;
static unsigned long payload_size;


/* Report ERRMSG on stderr with the name of the program, and exit with
   status 1. */
static void
die(const char *errmsg)
{
    fprintf(stderr, "%s: %s\n", progname, errmsg);
    exit(1);
}


/* The row at ROW of the index is a path, an offset and a size, and the
   data they give is in the barf. */
static int
row_ok(lua_State *L, int row)
{
    int ok;
    lua_Integer offset, size;

    lua_rawgeti(L, row, 1);
    lua_rawgeti(L, row, 2);
    lua_rawgeti(L, row, 3);
    offset = lua_tointeger(L, -2);
    size = lua_tointeger(L, -1);
    ok = lua_type(L, -3) == LUA_TSTRING && lua_type(L, -2) == LUA_TNUMBER
        && lua_type(L, -1) == LUA_TNUMBER && offset >= 0 && size >= 0 &&
        (unsigned long) size <= payload_size &&
        (unsigned long) offset <= payload_size - (unsigned long) size;
    lua_pop(L, 3);
    return ok;
}


/* Push a table that has the row of the index of the barf for each
   path.  Anything wrong with the barf is fatal, as it is a mistake of
   the build. */
static void
read_index(lua_State *L)
{
    const char *stop, *name, *data;
    unsigned long length, namelen, size, start;
    lua_Integer i, n;
    int index, map;

    /* The index is the first entry, and reading it writes nothing. */
    if (runtime_size < 25)
        die("there is no payload");
    stop = (const char *) runtime_data + runtime_size - 16;
    if (barf_length(stop, &length) || length < 9 ||
        length > runtime_size - 16 ||
        memcmp(stop - length, "!<barfx>\n", 9))
        die("the payload is not an indexed barf");
    if (barf_entry(stop - length + 9, stop, &name, &namelen, &data, &size) ||
        namelen != 5 || memcmp(name, "index", 5))
        die("the payload has no index");

    start = (unsigned long) (data - (const char *) runtime_data) + size + 1;
    payload = runtime_data + start;
    payload_size = (unsigned long) (stop - (const char *) runtime_data) -
        start;

    if (luaL_loadbuffer(L, data, size, "=index") ||
        lua_pcall(L, 0, 1, 0) || lua_type(L, -1) != LUA_TTABLE)
        die("the index of the payload is bad");
    index = lua_gettop(L);
    lua_newtable(L);
    map = lua_gettop(L);
    for (i = 1, n = luaL_len(L, index); i <= n; i++) {
        lua_rawgeti(L, index, i);
        if (lua_type(L, -1) != LUA_TTABLE || !row_ok(L, lua_gettop(L)))
            die("the index of the payload is bad");
        lua_rawgeti(L, -1, 1);
        lua_pushvalue(L, -2);
        lua_rawset(L, map);
        lua_pop(L, 1);
    }
    lua_remove(L, index);
}


/* Find the file PATH of the payload, with MAP, the table from the path
   of each to its row, at that index of the stack.  Set DATA and SIZE and
   return 1, or if there is no such file return 0. */
static int
find_payload(lua_State *L, int map, const char *path,
             const char **data, size_t *size)
{
    lua_Integer offset, length;

    lua_getfield(L, map, path);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return 0;
    }
    lua_rawgeti(L, -1, 2);
    lua_rawgeti(L, -2, 3);
    offset = lua_tointeger(L, -2);
    length = lua_tointeger(L, -1);
    lua_pop(L, 3);
    *data = (const char *) payload + offset;
    *size = (size_t) length;
    return 1;
}


/* Load the file PATH of the payload, with MAP at that index of the
   stack.  Push the function and return 0; or if there is no such file,
   push nothing and return 1; or if it does not compile, push why and
   return -1. */
static int
load_payload(lua_State *L, int map, const char *path)
{
    const char *data;
    size_t size;
    int status;

    if (!find_payload(L, map, path, &data, &size))
        return 1;
    lua_pushfstring(L, "@%s", path);
    status = luaL_loadbuffer(L, data, size, lua_tostring(L, -1));
    lua_remove(L, -2);
    return status == LUA_OK ? 0 : -1;
}


/* payload.read(path): the bytes of the file PATH of the payload, or nil
   if there is no such file.  The map is the upvalue. */
static int
payload_read(lua_State *L)
{
    const char *data;
    size_t size;

    if (!find_payload(L, lua_upvalueindex(1), luaL_checkstring(L, 1),
                      &data, &size))
        return 0;
    lua_pushlstring(L, data, size);
    return 1;
}


/* The loader of the module `smush.payload`, with the map as its upvalue. */
static int
open_payload(lua_State *L)
{
    lua_newtable(L);
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_pushcclosure(L, payload_read, 1);
    lua_setfield(L, -2, "read");
    return 1;
}


/* The searcher for require that finds a module in the payload, as
   either `a/b.lua` or `a/b/init.lua` for a.b. */
static int
searcher(lua_State *L)
{
    static const char *const forms[] = {"%s.lua", "%s/init.lua"};
    const char *name = luaL_checkstring(L, 1);
    const char *dir = luaL_gsub(L, name, ".", "/");
    const char *path;
    int i, found;

    for (i = 0; i < 2; i++) {
        path = lua_pushfstring(L, forms[i], dir);
        found = load_payload(L, lua_upvalueindex(1), path);
        if (found < 0)
            return luaL_error(L, "error loading module '%s' from the "
                              "payload:\n\t%s", name, lua_tostring(L, -1));
        if (!found) {
            lua_pushvalue(L, -2);
            return 2;
        }
        lua_pop(L, 1);
    }
    lua_pushfstring(L, NOT_FOUND "no file '%s.lua' or '%s/init.lua' in "
                    "the payload", dir, dir);
    return 1;
}


/* Make `require` find the modules of the program with MAP, the table
   from each path to its row, at that index of the stack: those that
   are in host_modules, if there are any, and then those in the payload,
   and no others. */
static void
install(lua_State *L, int map)
{
    int package;

    lua_getglobal(L, "package");
    package = lua_gettop(L);
    lua_getfield(L, package, "preload");
    lua_pushvalue(L, map);
    lua_pushcclosure(L, open_payload, 1);
    lua_setfield(L, -2, "smush.payload");
#ifdef HOST_MODULES
    {
        const luaL_Reg *m;

        for (m = host_modules; m->name; m++) {
            lua_pushcfunction(L, m->func);
            lua_setfield(L, -2, m->name);
        }
    }
#endif
    lua_pop(L, 1);

    /* The searchers (the loaders, in Lua 5.1) are the preload table, and
       then this. */
    lua_createtable(L, 2, 0);
    lua_getfield(L, package, SEARCHERS);
    lua_rawgeti(L, -1, 1);
    lua_rawseti(L, -3, 1);
    lua_pop(L, 1);
    lua_pushvalue(L, map);
    lua_pushcclosure(L, searcher, 1);
    lua_rawseti(L, -2, 2);
    lua_setfield(L, package, SEARCHERS);
    lua_settop(L, package - 1);
}


/* The message handler of a call: the message with a traceback. */
static int
traceback(lua_State *L)
{
    const char *msg = lua_tostring(L, 1);

    if (!msg)
        msg = lua_pushfstring(L, "(error object is a %s value)",
                              luaL_typename(L, 1));
    lua_getglobal(L, "debug");
    lua_getfield(L, -1, "traceback");
    lua_pushstring(L, msg);
    lua_pushinteger(L, 2);
    lua_call(L, 2, 1);
    return 1;
}


int
main(int argc, char **argv)
{
    lua_State *L;
    int i, map, handler;

    if (argc > 0 && argv[0] && *argv[0])
        progname = argv[0];
    if (!(L = luaL_newstate()))
        die("not enough memory");
    luaL_openlibs(L);
    read_index(L);
    map = lua_gettop(L);
    install(L, map);

    /* The arguments, from the program as arg[0], in `arg` and for the
       main chunk. */
    lua_createtable(L, argc, 1);
    for (i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");

    lua_pushcfunction(L, traceback);
    handler = lua_gettop(L);
    if (load_payload(L, map, "main.lua"))
        die("the payload has no main.lua");
    for (i = 1; i < argc; i++)
        lua_pushstring(L, argv[i]);
    if (lua_pcall(L, argc > 1 ? argc - 1 : 0, 0, handler)) {
        fprintf(stderr, "%s: %s\n", progname, lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }
    lua_close(L);
    return 0;
}
