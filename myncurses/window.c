#include "window.h"

#include <lauxlib.h>
#include <lua.h>

#include <ncurses.h>

#include <limits.h>

static char const window_name[] = "WINDOW*";

int checkint(lua_State* const L, int const arg)
{
    lua_Integer const i = luaL_checkinteger(L, arg);
    luaL_argcheck(L, INT_MIN <= i && i <= INT_MAX, arg, "out of range");
    return (int)i;
}

WINDOW* checkwindow(lua_State* const L, int const arg)
{
    WINDOW** const uptr = luaL_checkudata(L, arg, window_name);
    WINDOW* const win = *uptr;
    luaL_argcheck(L, NULL != win, arg, "WINDOW used after delwin");
    return win;
}

WINDOW* optwindow(lua_State* const L, int const arg)
{
    return luaL_opt(L, checkwindow, arg, stdscr);
}

static int l_delwin(lua_State* const L)
{
    WINDOW** const uptr = luaL_checkudata(L, 1, window_name);

    // Allow __gc to work on a explicitly closed window
    if (NULL == *uptr)
    {
        return 0;
    }

    if (ERR == delwin(*uptr))
    {
        return luaL_error(L, "delwin: ncurses error");
    }

    *uptr = NULL;

    return 0;
}

static int l_prefresh(lua_State* const L)
{
    WINDOW* const win = checkwindow(L, 1);
    int const pminrow = checkint(L, 2);
    int const pmincol = checkint(L, 3);
    int const sminrow = checkint(L, 4);
    int const smincol = checkint(L, 5);
    int const smaxrow = checkint(L, 6);
    int const smaxcol = checkint(L, 7);

    if (ERR == prefresh(win, pminrow, pmincol, sminrow, smincol, smaxrow, smaxcol))
    {
        return luaL_error(L, "prefresh: ncurses error");
    }
    return 0;
}

static int l_pnoutrefresh(lua_State* const L)
{
    WINDOW* const win = checkwindow(L, 1);
    int const pminrow = checkint(L, 2);
    int const pmincol = checkint(L, 3);
    int const sminrow = checkint(L, 4);
    int const smincol = checkint(L, 5);
    int const smaxrow = checkint(L, 6);
    int const smaxcol = checkint(L, 7);

    if (ERR == pnoutrefresh(win, pminrow, pmincol, sminrow, smincol, smaxrow, smaxcol))
    {
        return luaL_error(L, "pnoutrefresh: ncurses error");
    }
    return 0;
}

static int l_wresize(lua_State* const L)
{
    WINDOW* const win = checkwindow(L, 1);
    int const lines = checkint(L, 2);
    int const columns = checkint(L, 3);
    if (ERR == wresize(win, lines, columns))
    {
        return luaL_error(L, "wresize: ncurses error");
    }
    return 0;
}

static int l_wmove(lua_State* const L)
{
    WINDOW* const win = checkwindow(L, 1);
    int const y = checkint(L, 2);
    int const x = checkint(L, 3);
    if (ERR == wmove(win, y, x))
    {
        return luaL_error(L, "wmove: ncurses error");
    }
    return 0;
}

static int l_werase(lua_State* const L)
{
    WINDOW* const win = checkwindow(L, 1);
    if (ERR == werase(win))
    {
        return luaL_error(L, "werase: ncurses error");
    }
    return 0;
}

static int l_wclear(lua_State* const L)
{
    WINDOW* const win = checkwindow(L, 1);
    if (ERR == wclear(win))
    {
        return luaL_error(L, "wclear: ncurses error");
    }
    return 0;
}

static int l_waddstr(lua_State* const L)
{
    WINDOW* const win = checkwindow(L, 1);

    int const n = lua_gettop(L);
    for (int i = 2; i <= n; i++)
    {
        size_t len;
        char const* const str = luaL_checklstring(L, i, &len);
        (void)waddnstr(win, str, len);
        // waddnstr emits spurious errors writing to the end of a line
    }
    return 0;
}

static luaL_Reg const MT[] = {
    {"__gc", l_delwin},
    {"__close", l_delwin},
    {0}
};

static luaL_Reg const Methods[] = {
    {"delwin", l_delwin},
    {"wresize", l_wresize},
    {"wmove", l_wmove},
    {"werase", l_werase},
    {"wclear", l_wclear},
    {"prefresh", l_prefresh},
    {"pnoutrefresh", l_pnoutrefresh},
    {"waddstr", l_waddstr},
    {0}
};

void pushwindow(lua_State* const L, WINDOW* const win)
{
    WINDOW** const uptr = lua_newuserdatauv(L, sizeof win, 0);
    *uptr = win;

    if (luaL_newmetatable(L, window_name))
    {
        luaL_setfuncs(L, MT, 0);
        luaL_newlibtable(L, Methods);
        luaL_setfuncs(L, Methods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_setmetatable(L, -2);
}

int l_newwin(lua_State* const L)
{
    int const nlines = checkint(L, 1);
    int const ncols = checkint(L, 2);
    int const begin_y = checkint(L, 3);
    int const begin_x = checkint(L, 4);

    WINDOW* const result = newwin(nlines, ncols, begin_y, begin_x);

    if (NULL == result)
    {
        return luaL_error(L, "newwin: ncurses error");
    }

    pushwindow(L, result);
    return 1;
}

int l_newpad(lua_State* const L)
{
    int const nlines = checkint(L, 1);
    int const ncols = checkint(L, 2);

    WINDOW* const result = newpad(nlines, ncols);

    if (NULL == result)
    {
        return luaL_error(L, "newpad: ncurses error");
    }

    pushwindow(L, result);
    return 1;
}
