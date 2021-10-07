#define _XOPEN_SOURCE 600

#include <stdlib.h>

#include <ncurses.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "myncurses.h"

static int l_erase(lua_State *L)
{
    if (ERR == erase()) {
        return luaL_error(L, "erase: ncurses error");
    }
    return 0;
}

static int l_clear(lua_State *L)
{
    if (ERR == clear()) {
        return luaL_error(L, "clear: ncurses error");
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
    if (ERR == attr_on(a, NULL)) {
        return luaL_error(L, "attron: ncurses error");
    }
    return 0;
}

static int l_attroff(lua_State *L)
{
    int a = luaL_checkinteger(L, 1);
    if (ERR == attr_off(a, NULL)) {
        return luaL_error(L, "attroff: ncurses error");
    }
    return 0;
}

static int l_attrset(lua_State *L)
{
    int a = luaL_checkinteger(L, 1);
    int color = luaL_checkinteger(L, 2);
    if (ERR == attr_set(a, color, NULL)) {
        return luaL_error(L, "attrset: ncurses error");
    }
    return 0;
}

static int l_addstr(lua_State *L)
{
    size_t len;
    char const* str = luaL_checklstring(L, 1, &len);
    addnstr(str, len);
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

    if (0 <= y && 0 <= x && y < wy && x < wx)
    {
        mvaddnstr(y, x, str, len);
    }
    return 0;
}

static int l_getyx(lua_State *L)
{
    int y, x;
    getyx(stdscr, y, x);
    lua_pushinteger(L, y);
    lua_pushinteger(L, x);
    return 2;
}

static int l_colorset(lua_State *L)
{
    int color = luaL_checkinteger(L, 1);
    if (ERR == color_set(color, NULL)) 
    {
        return luaL_error(L, "color_set: ncurses error");
    }
    return 0;
}

static luaL_Reg lib[] = {
    {"addstr", l_addstr},
    {"mvaddstr", l_mvaddstr},
    {"getyx", l_getyx},

    {"refresh", l_refresh},
    {"erase", l_erase},
    {"clear", l_clear},

    {"attron", l_attron},
    {"attroff", l_attroff},
    {"attrset", l_attrset},
    {"colorset", l_colorset},
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
    lua_pushinteger(L, i);
    lua_setfield(L, -2, name);
}

#define LCURSES__SPLICE(_s, _t) _s##_t
#define LCURSES_SPLICE(_s, _t) LCURSES__SPLICE(_s, _t)
#define LCURSES__STR(_s) #_s
#define LCURSES_STR(_s) LCURSES__STR(_s)

#define CCR(n, v) do { \
	lua_pushinteger(L, v); \
	lua_setfield(L, -2, n); \
} while(0)

#define CC(s) CCR(#s, s)
#define CF(i) CCR(LCURSES_STR(LCURSES_SPLICE(KEY_F, i)), KEY_F(i))

int luaopen_myncurses(lua_State *L)
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

	/* attributes */
	CC(WA_NORMAL);		CC(WA_STANDOUT);		CC(WA_UNDERLINE);
	CC(WA_REVERSE);		CC(WA_BLINK);		CC(WA_DIM);
	CC(WA_BOLD);        CC(WA_ALTCHARSET);

	CC(KEY_DOWN);		CC(KEY_UP);         CC(KEY_END);
	CC(KEY_LEFT);		CC(KEY_RIGHT);		CC(KEY_HOME);
	CC(KEY_BACKSPACE);  CC(KEY_PPAGE);      CC(KEY_NPAGE);

	CF( 1); CF( 2); CF( 3); CF( 4); CF( 5); CF( 6); CF( 7); 
    CF( 8); CF( 9); CF(10); CF(11); CF(12);

    return 1;
}
