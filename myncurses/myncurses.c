#define _XOPEN_SOURCE 600

#include <stdlib.h>
#include <assert.h>

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
        return luaL_error(L, "refresh: ncurses error");
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
    // map [fore][back] to a pair number - zero for unassigned (except for [-1][-1])
    static int color_map[9][9]; // colors range from -1 to 7
    static int assigned = 1;

    lua_Integer fore = luaL_optinteger(L, 1, -1);
    luaL_argcheck(L, -1 <= fore && fore <= 7, 1, "out of range");

    lua_Integer back = luaL_optinteger(L, 2, -1);
    luaL_argcheck(L, -1 <= back && back <= 7, 2, "out of range");

    int* pair = &color_map[fore+1][back+1];
    if (0 == *pair && (fore >= 0 || back >= 0)) {
        if (assigned < COLOR_PAIRS) {
            *pair = assigned++;
            int result = init_pair(*pair, fore, back);
            assert(ERR != result);
        }
    }

    if (ERR == color_set(*pair, NULL)) {
        return luaL_error(L, "color_set: ncurses error");
    }

    return 0;
}

static int l_move(lua_State *L)
{
    lua_Integer y = luaL_checkinteger(L, 1);
    lua_Integer x = luaL_checkinteger(L, 2);
    if (ERR == move(y, x))
    {
        return luaL_error(L, "move");
    }
    return 0;
}

static int l_cursset(lua_State *L)
{
    lua_Integer visibility = luaL_checkinteger(L, 1);
    int previous = curs_set(visibility);
    if (previous == ERR)
    {
        return luaL_error(L, "curs_set: invalid argument");
    }
    lua_pushinteger(L, previous);
    return 1;
}

static int l_flash(lua_State *L)
{
    flash();
    return 0;
}

static int l_beep(lua_State *L)
{
    beep();
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

    {"cursset", l_cursset},
    {"move", l_move},
    {"beep", l_beep},
    {"flash", l_flash},
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

struct color
{
    char const* name;
    short value;
};

static struct color colors[] = {
    { "default", -1},
    { "black", COLOR_BLACK },
    { "red", COLOR_RED },
    { "green", COLOR_GREEN },
    { "yellow", COLOR_YELLOW },
    { "blue", COLOR_BLUE },
    { "magenta", COLOR_MAGENTA },
    { "cyan", COLOR_CYAN },
    { "white", COLOR_WHITE },
};

static void setup_colors(lua_State *L)
{
    for (int i = 1; i < 9; i++)
    {
        lua_pushinteger(L, colors[i].value);
        lua_setfield(L, -2, colors[i].name);
    }
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
    setup_colors(L);

	/* attributes */
	CC(WA_NORMAL);      CC(WA_STANDOUT);    CC(WA_UNDERLINE);
	CC(WA_REVERSE);     CC(WA_BLINK);       CC(WA_DIM);
	CC(WA_BOLD);        CC(WA_ALTCHARSET);  CC(WA_ITALIC);

	CC(KEY_DOWN);       CC(KEY_UP);         CC(KEY_END);
	CC(KEY_LEFT);       CC(KEY_RIGHT);      CC(KEY_HOME);
	CC(KEY_BACKSPACE);  CC(KEY_PPAGE);      CC(KEY_NPAGE);
    CC(KEY_DC);         CC(KEY_BTAB);

	CF( 1); CF( 2); CF( 3); CF( 4); CF( 5); CF( 6); CF( 7); 
    CF( 8); CF( 9); CF(10); CF(11); CF(12);

    return 1;
}
