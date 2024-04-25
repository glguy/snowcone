#include "window.h"

#include <lua.h>
#include <lauxlib.h>
#include <ncurses.h>

WINDOW* checkwindow(lua_State* const L, int const arg)
{
    WINDOW** const uptr = luaL_checkudata(L, arg, "WINDOW");
    WINDOW* const win = *uptr;
    luaL_argcheck(L, NULL != win, arg, "WINDOW used after delwin");
    return win;
}

WINDOW* optwindow(lua_State* const L, int const arg)
{
    if (lua_isnoneornil(L, arg))
    {
        return stdscr;
    }
    return checkwindow(L, arg);
}

static int l_delwin(lua_State* const L)
{
    WINDOW** const uptr = luaL_checkudata(L, 1, "WINDOW");

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
    lua_Integer const pminrow = luaL_checkinteger(L, 2);
    lua_Integer const pmincol = luaL_checkinteger(L, 3);
    lua_Integer const sminrow = luaL_checkinteger(L, 4);
    lua_Integer const smincol = luaL_checkinteger(L, 5);
    lua_Integer const smaxrow = luaL_checkinteger(L, 6);
    lua_Integer const smaxcol = luaL_checkinteger(L, 7);

    if (ERR == prefresh(win, pminrow, pmincol, sminrow, smincol, smaxrow, smaxcol))
    {
        return luaL_error(L, "prefresh: ncurses error");
    }
    return 0;
}

static int l_pnoutrefresh(lua_State* const L)
{
    WINDOW* const win = checkwindow(L, 1);
    lua_Integer const pminrow = luaL_checkinteger(L, 2);
    lua_Integer const pmincol = luaL_checkinteger(L, 3);
    lua_Integer const sminrow = luaL_checkinteger(L, 4);
    lua_Integer const smincol = luaL_checkinteger(L, 5);
    lua_Integer const smaxrow = luaL_checkinteger(L, 6);
    lua_Integer const smaxcol = luaL_checkinteger(L, 7);

    if (ERR == pnoutrefresh(win, pminrow, pmincol, sminrow, smincol, smaxrow, smaxcol))
    {
        return luaL_error(L, "pnoutrefresh: ncurses error");
    }
    return 0;
}

static int l_wresize(lua_State* const L)
{
    WINDOW* const win = checkwindow(L, 1);
    lua_Integer const lines = luaL_checkinteger(L, 2);
    lua_Integer const columns = luaL_checkinteger(L, 3);
    if (ERR == wresize(win, lines, columns))
    {
        return luaL_error(L, "wresize: ncurses error");
    }
    return 0;
}

static int l_wmove(lua_State* const L)
{
    WINDOW* const win = checkwindow(L, 1);
    lua_Integer const y = luaL_checkinteger(L, 2);
    lua_Integer const x = luaL_checkinteger(L, 3);
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
    for (int i = 2; i <= n; i++) {
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
    {"wmove", l_wmove},
    {0}
};

void pushwindow(lua_State* const L, WINDOW* const win)
{
    WINDOW** const uptr = lua_newuserdatauv(L, sizeof win, 0);
    *uptr = win;

    if (luaL_newmetatable(L, "WINDOW"))
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
    lua_Integer const nlines = luaL_checkinteger(L, 1);
    lua_Integer const ncols = luaL_checkinteger(L, 2);
    lua_Integer const begin_y = luaL_checkinteger(L, 3);
    lua_Integer const begin_x = luaL_checkinteger(L, 4);

    WINDOW *const result = newwin(nlines, ncols, begin_y, begin_x);

    if (NULL == result)
    {
        return luaL_error(L, "newwin: ncurses error");
    }

    pushwindow(L, result);
    return 1;
}

int l_newpad(lua_State* const L)
{
    lua_Integer const nlines = luaL_checkinteger(L, 1);
    lua_Integer const ncols = luaL_checkinteger(L, 2);

    WINDOW *const result = newpad(nlines, ncols);

    if (NULL == result)
    {
        return luaL_error(L, "newpad: ncurses error");
    }

    pushwindow(L, result);
    return 1;
}
