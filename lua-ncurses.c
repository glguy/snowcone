#define _XOPEN_SOURCE 600

#include <lua5.3/lua.h>
#include <ncurses.h>
#include <lua5.3/lauxlib.h>
#include <lua5.3/lualib.h>
#include <wchar.h>
#include <stdlib.h>

#include "lua-ncurses.h"

static int l_erase(lua_State *L)
{
    if (ERR == erase()) {
        return luaL_error(L, "ncurses error");
    }
    return 0;
}

static int l_clear(lua_State *L)
{
    if (ERR == clear()) {
        return luaL_error(L, "ncurses error");
    }
    return 0;
}

static int l_refresh(lua_State *L)
{
    if (ERR == refresh()) {
        return luaL_error(L, "ncurses error");
    }
    return 0;
}

static int l_attron(lua_State *L)
{
    int a = luaL_checkinteger(L, 1);
    if (ERR == attron(a)) {
        return luaL_error(L, "ncurses error");
    }
    return 0;
}

static int l_attroff(lua_State *L)
{
    int a = luaL_checkinteger(L, 1);
    if (ERR == attroff(a)) {
        return luaL_error(L, "ncurses error");
    }
    return 0;
}

static int l_attrset(lua_State *L)
{
    int a = luaL_checkinteger(L, 1);
    if (ERR == attrset(a)) {
        return luaL_error(L, "ncurses error");
    }
    return 0;
}

static int l_addstr(lua_State *L)
{
    size_t len;
    char const* str = luaL_checklstring(L, 1, &len);

    int wy, wx, y, x;
    getmaxyx(stdscr, wy, wx);
    getyx(stdscr, y, x);
    
    wchar_t *wstr = lua_newuserdata(L, sizeof(wchar_t) * len);
    size_t wlen = mbstowcs(wstr, str, len);
    int width = wcswidth(wstr, wlen);

    if (width != -1 && y < wy && x+width < wx)
    {
        if (ERR == addnwstr(wstr, wlen)) {
            return luaL_error(L, "ncurses error");
        }
    }
    return 0;
}

static int l_mvaddstr(lua_State *L)
{
    int y = luaL_checkinteger(L, 1);
    int x = luaL_checkinteger(L, 2);
    size_t len;
    char const* str = luaL_checklstring(L, 3, &len);

    int wy, wx;
    getmaxyx(stdscr, wy, wx);

    wchar_t *wstr = lua_newuserdata(L, sizeof(wchar_t) * len);
    size_t wlen = mbstowcs(wstr, str, len);
    int width = wcswidth(wstr, wlen);

    if (width != -1 && y < wy && x+width <= wx)
    {
        if (ERR == mvaddnwstr(y, x, wstr, wlen)) {
            return luaL_error(L, "ncurses error");
        }
    }
    return 0;
}

static luaL_Reg lib[] = {
    {"addstr", l_addstr},
    {"mvaddstr", l_mvaddstr},

    {"refresh", l_refresh},
    {"erase", l_erase},
    {"clear", l_clear},

    {"attron", l_attron},
    {"attroff", l_attroff},
    {"attrset", l_attrset},
    {},
};

void l_ncurses_resize(lua_State *L)
{
    int y, x;
    getmaxyx(stdscr, y, x);
    lua_pushinteger(L, x);
    lua_setglobal(L, "tty_width");
    lua_pushinteger(L, y);
    lua_setglobal(L, "tty_height");
}

static inline void setup_color(lua_State *L, short i, short f, short b, char const* name)
{
    init_pair(i, f, b);
    lua_pushinteger(L, COLOR_PAIR(i));
    lua_setfield(L, -2, name);
}

int luaopen_ncurses(lua_State *L)
{
    luaL_newlib(L, lib);
    setup_color(L, 1, COLOR_RED, -1, "red");
    setup_color(L, 2, COLOR_GREEN, -1, "green");
    setup_color(L, 3, COLOR_YELLOW, -1, "yellow");
    setup_color(L, 4, COLOR_BLUE, -1, "blue");
    setup_color(L, 5, COLOR_MAGENTA, -1, "magenta");
    setup_color(L, 6, COLOR_CYAN, -1, "cyan");
    setup_color(L, 7, COLOR_WHITE, -1, "white");
    setup_color(L, 8, COLOR_BLACK, -1, "black");

    lua_pushinteger(L, A_BOLD);
    lua_setfield(L, -2, "bold");

    lua_pushinteger(L, A_UNDERLINE);
    lua_setfield(L, -2, "underline");

    lua_pushinteger(L, A_NORMAL);
    lua_setfield(L, -2, "normal");

    return 1;
}