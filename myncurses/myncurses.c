#define _XOPEN_SOURCE 600

#include "myncurses.h"
#include "window.h"

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <ncurses.h>

#include <stdlib.h>

static int l_erase(lua_State* const L)
{
    WINDOW* const win = optwindow(L, 1);

    if (ERR == werase(win))
    {
        return luaL_error(L, "erase: ncurses error");
    }
    return 0;
}

static int l_clear(lua_State* const L)
{
    WINDOW* const win = optwindow(L, 1);

    if (ERR == wclear(win))
    {
        return luaL_error(L, "clear: ncurses error");
    }
    return 0;
}

static int l_refresh(lua_State* const L)
{
    WINDOW* const win = optwindow(L, 1);

    if (ERR == wrefresh(win))
    {
        return luaL_error(L, "refresh: ncurses error");
    }
    return 0;
}

static int l_noutrefresh(lua_State* const L)
{
    WINDOW* const win = optwindow(L, 1);

    if (ERR == wnoutrefresh(win))
    {
        return luaL_error(L, "wnoutrefresh: ncurses error");
    }
    return 0;
}

static int l_attron(lua_State* const L)
{
    lua_Integer const a = luaL_checkinteger(L, 1);
    WINDOW* const win = optwindow(L, 2);

    if (ERR == wattr_on(win, a, NULL))
    {
        return luaL_error(L, "wattr_on: ncurses error");
    }
    return 0;
}

static int l_attroff(lua_State* const L)
{
    lua_Integer const a = luaL_checkinteger(L, 1);
    WINDOW* const win = optwindow(L, 2);

    if (ERR == wattr_off(win, a, NULL))
    {
        return luaL_error(L, "wattr_off: ncurses error");
    }
    return 0;
}

static int l_attrget(lua_State* const L)
{
    WINDOW* const win = optwindow(L, 1);

    attr_t attrs;
    short colorpair;
    if (ERR == wattr_get(win, &attrs, &colorpair, NULL))
    {
        return luaL_error(L, "wattr_get: ncurses error");
    }

    lua_pushinteger(L, attrs);
    lua_pushinteger(L, colorpair);
    return 2;
}

static int l_attrset(lua_State* const L)
{
    int const a = luaL_checkinteger(L, 1);
    int const color = luaL_checkinteger(L, 2);
    WINDOW* const win = optwindow(L, 3);

    if (ERR == wattr_set(win, a, color, NULL))
    {
        return luaL_error(L, "wattr_set: ncurses error");
    }
    return 0;
}

static int l_addstr(lua_State* const L)
{
    int const n = lua_gettop(L);
    for (int i = 1; i <= n; i++)
    {
        size_t len;
        char const* const str = luaL_checklstring(L, i, &len);
        addnstr(str, len);
    }
    return 0;
}

static int l_mvaddstr(lua_State* const L)
{
    int const y = luaL_checkinteger(L, 1);
    int const x = luaL_checkinteger(L, 2);
    size_t len;
    int const n = lua_gettop(L);

    int wy, wx;
    getmaxyx(stdscr, wy, wx);

    if (0 <= y && 0 <= x && y < wy && x < wx)
    {
        if (n < 3)
        {
            move(y, x);
        }
        else
        {
            char const* const str = luaL_checklstring(L, 3, &len);
            mvaddnstr(y, x, str, len);

            for (int i = 4; i <= n; i++)
            {
                char const* const str = luaL_checklstring(L, i, &len);
                addnstr(str, len);
            }
        }
    }
    return 0;
}

static int l_getyx(lua_State* const L)
{
    WINDOW* const win = optwindow(L, 1);

    int y, x;
    getyx(win, y, x);
    lua_pushinteger(L, y);
    lua_pushinteger(L, x);
    return 2;
}

static int l_getmaxyx(lua_State* const L)
{
    WINDOW* const win = optwindow(L, 1);

    int y, x;
    getmaxyx(win, y, x);
    lua_pushinteger(L, y);
    lua_pushinteger(L, x);
    return 2;
}

static int l_doupdate(lua_State* const L)
{
    if (ERR == doupdate())
    {
        return luaL_error(L, "doupdate: ncurses error");
    }
    return 0;
}

static int l_colorset(lua_State* const L)
{
    // map [fore][back] to a pair number - zero for unassigned (except for [-1][-1])
    static int color_map[9][9]; // colors range from -1 to 7
    static int assigned = 1;

    lua_Integer fore = luaL_optinteger(L, 1, -1);
    luaL_argcheck(L, -1 <= fore && fore <= 7, 1, "out of range");

    lua_Integer back = luaL_optinteger(L, 2, -1);
    luaL_argcheck(L, -1 <= back && back <= 7, 2, "out of range");

    WINDOW* const win = optwindow(L, 3);

    int* pair = &color_map[fore + 1][back + 1];
    if (0 == *pair && (fore >= 0 || back >= 0))
    {
        if (assigned < COLOR_PAIRS)
        {
            *pair = assigned++;
            init_pair(*pair, fore, back);
        }
    }

    if (ERR == wcolor_set(win, *pair, NULL))
    {
        return luaL_error(L, "color_set: ncurses error");
    }

    return 0;
}

static int l_move(lua_State* const L)
{
    lua_Integer y = luaL_checkinteger(L, 1);
    lua_Integer x = luaL_checkinteger(L, 2);
    WINDOW* const win = optwindow(L, 3);
    if (ERR == wmove(win, y, x))
    {
        return luaL_error(L, "move");
    }
    return 0;
}

static int l_cursset(lua_State* const L)
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

static int l_flash(lua_State* const L)
{
    flash();
    return 0;
}

static int l_beep(lua_State* const L)
{
    beep();
    return 0;
}

static luaL_Reg lib[] = {
    {"addstr", l_addstr},
    {"mvaddstr", l_mvaddstr},
    {"getyx", l_getyx},
    {"getmaxyx", l_getmaxyx},

    {"refresh", l_refresh},
    {"noutrefresh", l_noutrefresh},
    {"erase", l_erase},
    {"clear", l_clear},

    {"attron", l_attron},
    {"attroff", l_attroff},
    {"attrset", l_attrset},
    {"attrget", l_attrget},
    {"colorset", l_colorset},

    {"cursset", l_cursset},
    {"move", l_move},
    {"beep", l_beep},
    {"flash", l_flash},

    {"newwin", l_newwin},
    {"newpad", l_newpad},
    {"doupdate", l_doupdate},
    {0},
};

void l_ncurses_resize(lua_State* const L)
{
    int y, x;
    getmaxyx(stdscr, y, x);
    lua_pushinteger(L, x);
    lua_setglobal(L, "tty_width");
    lua_pushinteger(L, y);
    lua_setglobal(L, "tty_height");
}

#define LCURSES__SPLICE(_s, _t) _s##_t
#define LCURSES_SPLICE(_s, _t) LCURSES__SPLICE(_s, _t)
#define LCURSES__STR(_s) #_s
#define LCURSES_STR(_s) LCURSES__STR(_s)

#define CCR(n, v)               \
    do                          \
    {                           \
        lua_pushinteger(L, v);  \
        lua_setfield(L, -2, n); \
    }                           \
    while (0)

#define CC(s) CCR(#s, s)
#define CF(i) CCR(LCURSES_STR(LCURSES_SPLICE(KEY_F, i)), KEY_F(i))

int luaopen_myncurses(lua_State* L)
{
    luaL_newlib(L, lib);

    /* colors */
    CC(COLOR_BLACK);
    CC(COLOR_RED);
    CC(COLOR_GREEN);
    CC(COLOR_YELLOW);
    CC(COLOR_BLUE);
    CC(COLOR_MAGENTA);
    CC(COLOR_CYAN);
    CC(COLOR_WHITE);
    CCR("COLOR_DEFAULT", -1);

    /* attributes */
    CC(WA_NORMAL);
    CC(WA_STANDOUT);
    CC(WA_UNDERLINE);
    CC(WA_REVERSE);
    CC(WA_BLINK);
    CC(WA_DIM);
    CC(WA_BOLD);
    CC(WA_ALTCHARSET);
    CC(WA_ITALIC);

    CC(KEY_DOWN);
    CC(KEY_UP);
    CC(KEY_END);
    CC(KEY_LEFT);
    CC(KEY_RIGHT);
    CC(KEY_HOME);
    CC(KEY_BACKSPACE);
    CC(KEY_PPAGE);
    CC(KEY_NPAGE);
    CC(KEY_DC);
    CC(KEY_BTAB);

    CC(KEY_RESUME);
    CC(KEY_EXIT);

    CF(1);
    CF(2);
    CF(3);
    CF(4);
    CF(5);
    CF(6);
    CF(7);
    CF(8);
    CF(9);
    CF(10);
    CF(11);
    CF(12);

    return 1;
}
