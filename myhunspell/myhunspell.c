// Lua binding to libhunspell: open a dictionary from its .aff and .dic
// files, check words, suggest spellings, and add words to the open
// dictionary. Words are passed to hunspell as bytes, unconverted, so they
// must already be in the dictionary's encoding (see encoding()).

#include "myhunspell.h"

#include <hunspell.h>

#include <lauxlib.h>
#include <lua.h>

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static char const* handle_type_name = "Hunhandle*";
static char const* suggestions_type_name = "myhunspell.suggestions";

// Raises the formatted message as it is, without the caller's position:
// these are shown to the user as they are. Never returns.
static int fail(lua_State* L, char const* fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    lua_pushvfstring(L, fmt, ap);
    va_end(ap);
    return lua_error(L);
}

// The open handle at argument 1; raises an argument error if it isn't a
// handle, and an error if it has been closed.
static Hunhandle* check_handle(lua_State* L)
{
    Hunhandle** h = luaL_checkudata(L, 1, handle_type_name);
    if (NULL == *h)
        luaL_error(L, "hunspell handle is closed");
    return *h;
}

// The string at argument arg, as hunspell takes a word or path: a C
// string, so one with an embedded NUL raises an argument error rather than
// hiding its tail.
static char const* check_word(lua_State* L, int arg)
{
    size_t len;
    char const* word = luaL_checklstring(L, arg, &len);
    luaL_argcheck(L, strlen(word) == len, arg, "contains NUL");
    return word;
}

// Lua: handle:close(), also __gc and __close. Destroys the hunspell
// handle; closing again does nothing, and other methods then raise.
static int close_handle(lua_State* L)
{
    Hunhandle** h = luaL_checkudata(L, 1, handle_type_name);
    if (NULL != *h)
    {
        Hunspell_destroy(*h);
        *h = NULL;
    }
    return 0;
}

// Hunspell doesn't say when a file is missing or isn't a dictionary: it
// opens an empty one, with complaints on stderr, over the screen. So the
// files are checked first: regular files that can be read, the .dic
// starting with its word count.
//
// Raises "<path>: <reason>" unless path names a regular file this process
// can open for reading.
static void check_regular(lua_State* L, char const* path)
{
    struct stat st;
    if (0 != stat(path, &st))
        fail(L, "%s: %s", path, strerror(errno));
    if (!S_ISREG(st.st_mode))
        fail(L, "%s: not a regular file", path);
    FILE* f = fopen(path, "r");
    if (NULL == f)
        fail(L, "%s: %s", path, strerror(errno));
    fclose(f);
}

// Raises "<path>: not a hunspell dictionary (no word count)" unless the
// file's first line (after any UTF-8 byte order mark) starts with a
// positive integer; raises "<path>: <reason>" if it can't be opened.
static void check_dic(lua_State* L, char const* path)
{
    FILE* f = fopen(path, "r");
    if (NULL == f)
        fail(L, "%s: %s", path, strerror(errno));
    char line[64];
    char* got = fgets(line, sizeof line, f);
    fclose(f);
    char* start = line;
    if (got && 0 == strncmp(start, "\xEF\xBB\xBF", 3))
        start += 3; // a UTF-8 byte order mark
    char* end;
    long count = got ? strtol(start, &end, 10) : 0;
    if (!got || end == start || count <= 0)
        fail(L, "%s: not a hunspell dictionary (no word count)", path);
}

// Lua: open(aff, dic) -> handle
// Opens the dictionary from the paths of its affix and word files. Raises
// with an unpositioned "<path>: <reason>" message when either file is
// missing, unreadable, or not a regular file, or the .dic has no word
// count. The handle is closed by close(), __close, or __gc.
static int open_handle(lua_State* L)
{
    char const* aff = check_word(L, 1);
    char const* dic = check_word(L, 2);
    check_regular(L, aff);
    check_regular(L, dic);
    check_dic(L, dic);

    // the userdata comes first so that, should allocating it raise, no
    // hunspell handle has been made yet to leak
    Hunhandle** ptr = lua_newuserdatauv(L, sizeof *ptr, 0);
    *ptr = NULL;
    luaL_setmetatable(L, handle_type_name);
    *ptr = Hunspell_create(aff, dic);
    if (NULL == *ptr)
        fail(L, "hunspell could not open %s", dic);
    return 1;
}

// Lua: handle:spell(word) -> boolean
// Whether the dictionary accepts word.
static int spell(lua_State* L)
{
    Hunhandle* h = check_handle(L);
    char const* word = check_word(L, 2);
    lua_pushboolean(L, Hunspell_spell(h, word));
    return 1;
}

// Hunspell's list of suggestions, freed when suggest returns or raises:
// suggest marks it to-be-closed. h is the handle the list came from.
struct suggestions
{
    Hunhandle* h;
    char** list;
    int n;
};

// __gc and __close of a suggestions list: frees it with the handle it came
// from, once.
static int free_suggestions(lua_State* L)
{
    struct suggestions* s = luaL_checkudata(L, 1, suggestions_type_name);
    if (NULL != s->list)
    {
        Hunspell_free_list(s->h, &s->list, s->n);
        s->list = NULL;
    }
    return 0;
}

// Lua: handle:suggest(word) -> {string...}
// Hunspell's suggested spellings for word, best first; an empty table when
// it has none.
static int suggest(lua_State* L)
{
    Hunhandle* h = check_handle(L);
    char const* word = check_word(L, 2);

    struct suggestions* s = lua_newuserdatauv(L, sizeof *s, 0);
    s->h = h;
    s->list = NULL;
    s->n = 0;
    luaL_setmetatable(L, suggestions_type_name);
    lua_toclose(L, -1);

    s->n = Hunspell_suggest(h, &s->list, word);
    lua_createtable(L, s->n > 0 ? s->n : 0, 0);
    for (int i = 0; i < s->n; i++)
    {
        lua_pushstring(L, s->list[i]);
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

// Lua: handle:add(word)
// Accepts word, with no affixes, until the handle is closed; the
// dictionary's files are not changed.
static int add(lua_State* L)
{
    Hunhandle* h = check_handle(L);
    char const* word = check_word(L, 2);
    Hunspell_add(h, word);
    return 0;
}

// Lua: handle:encoding() -> string
// The dictionary's encoding as its .aff names it (SET), such as "UTF-8" or
// "ISO8859-1", the spelling hunspell defaults to.
static int encoding(lua_State* L)
{
    Hunhandle* h = check_handle(L);
    char const* enc = Hunspell_get_dic_encoding(h);
    lua_pushstring(L, enc ? enc : "ISO8859-1"); // hunspell's own default
    return 1;
}

// Module functions
static luaL_Reg M[] = {
    {"open", open_handle},
    {0},
};

// Methods of a hunspell handle
static luaL_Reg HandleM[] = {
    {"spell", spell},
    {"suggest", suggest},
    {"add", add},
    {"encoding", encoding},
    {"close", close_handle},
    {0},
};

int luaopen_myhunspell(lua_State* L)
{
    if (luaL_newmetatable(L, handle_type_name))
    {
        lua_pushcfunction(L, close_handle);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, close_handle);
        lua_setfield(L, -2, "__close");
        luaL_newlib(L, HandleM);
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);

    if (luaL_newmetatable(L, suggestions_type_name))
    {
        lua_pushcfunction(L, free_suggestions);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, free_suggestions);
        lua_setfield(L, -2, "__close");
    }
    lua_pop(L, 1);

    luaL_newlib(L, M);
    return 1;
}
