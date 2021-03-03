#include <ncurses.h>

#include <lua5.3/lauxlib.h>
#include <lua5.3/lualib.h>

#include "lua-ncurses.h"

static int l_red(lua_State *L)
{
    if (ERR == attron(COLOR_PAIR(1))) {
        return luaL_error(L, "ncurses red failed");
    }
    return 0;
}

static int l_green(lua_State *L)
{
    if (ERR == attron(COLOR_PAIR(2))) {
        return luaL_error(L, "ncurses green failed");
    }
    return 0;
}

static int l_yellow(lua_State *L)
{
    if (ERR == attron(COLOR_PAIR(3))) {
        return luaL_error(L, "ncurses yellow failed");
    }
    return 0;
}

static int l_blue(lua_State *L)
{
    if (ERR == attron(COLOR_PAIR(4))) {
        return luaL_error(L, "ncurses blue failed");
    }
    return 0;
}

static int l_magenta(lua_State *L)
{
    if (ERR == attron(COLOR_PAIR(5))) {
        return luaL_error(L, "ncurses magenta failed");
    }
    return 0;
}

static int l_cyan(lua_State *L)
{
    if (ERR == attron(COLOR_PAIR(6))) {
        return luaL_error(L, "ncurses cyan failed");
    }
    return 0;
}

static int l_white(lua_State *L)
{
    if (ERR == attron(COLOR_PAIR(7))) {
        return luaL_error(L, "ncurses white failed");
    }
    return 0;
}

static int l_black(lua_State *L)
{
    if (ERR == attron(COLOR_PAIR(8))) {
        return luaL_error(L, "ncurses black failed");
    }
    return 0;
}

static int l_bold(lua_State *L)
{
    if (ERR == attron(A_BOLD)) {
        return luaL_error(L, "ncurses bold failed");
    }
    return 0;
}

static int l_underline(lua_State *L)
{
    if (ERR == attron(A_UNDERLINE)) {
        return luaL_error(L, "ncurses bold failed");
    }
    return 0;
}

static int l_normal(lua_State *L)
{
    if (ERR == attrset(A_NORMAL)) {
        return luaL_error(L, "ncurses normal failed");
    }
    return 0;
}

static int l_erase(lua_State *L)
{
    if (ERR == erase()) {
        return luaL_error(L, "ncurses erase failed");
    }
    return 0;
}

static int l_clear(lua_State *L)
{
    if (ERR == clear()) {
        return luaL_error(L, "ncurses clear failed");
    }
    return 0;
}

static int l_refresh(lua_State *L)
{
    if (ERR == refresh()) {
        return luaL_error(L, "ncurses refresh failed");
    }
    return 0;
}

static int l_addstr(lua_State *L)
{
    char const* str = luaL_checkstring(L, 1);
    if (ERR == addstr(str)) {
        return luaL_error(L, "ncurses addstr failed");
    }
    return 0;
}

static int l_mvaddstr(lua_State *L)
{
    int y = luaL_checkinteger(L, 1);
    int x = luaL_checkinteger(L, 2);
    char const* str = luaL_checkstring(L, 3);
    if (ERR == mvaddstr(y, x, str)) {
        return luaL_error(L, "ncurses mvaddstr failed");
    }
    return 0;
}

static luaL_Reg lib[] = {
    {"addstr", l_addstr},
    {"mvaddstr", l_mvaddstr},

    {"refresh", l_refresh},
    {"erase", l_erase},
    {"clear", l_clear},

    {"bold", l_bold},
    {"normal", l_normal},
    {"underline", l_underline},

    {"red", l_red},
    {"green", l_green},
    {"yellow", l_yellow},
    {"blue", l_blue},
    {"magenta", l_magenta},
    {"cyan", l_cyan},
    {"white", l_white},
    {"black", l_black},
    {},
};

int luaopen_ncurses(lua_State *L)
{
    init_pair(1, COLOR_RED, -1);
    init_pair(2, COLOR_GREEN, -1);
    init_pair(3, COLOR_YELLOW, -1);
    init_pair(4, COLOR_BLUE, -1);
    init_pair(5, COLOR_MAGENTA, -1);
    init_pair(6, COLOR_CYAN, -1);
    init_pair(7, COLOR_WHITE, -1);
    init_pair(8, COLOR_BLACK, -1);

    luaL_newlib(L, lib);
    return 1;
}