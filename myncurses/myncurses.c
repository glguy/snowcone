// Lua binding for ncurses: the module's functions and constants. Functions
// taking an optional window use stdscr when it is nil or absent, and raise
// "<name>: ncurses error" when ncurses fails, unless noted.

#define _XOPEN_SOURCE 600

#include "myncurses.h"
#include "colorpairs.h"
#include "window.h"

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <ncurses.h>

#include <stdlib.h>

// Lua: erase([win]). Blanks the window.
static int l_erase(lua_State* const L)
{
    WINDOW* const win = optwindow(L, 1);

    if (ERR == werase(win))
    {
        return luaL_error(L, "erase: ncurses error");
    }
    return 0;
}

// Lua: clear([win]). As erase, and the terminal is cleared on the next
// refresh.
static int l_clear(lua_State* const L)
{
    WINDOW* const win = optwindow(L, 1);

    if (ERR == wclear(win))
    {
        return luaL_error(L, "clear: ncurses error");
    }
    return 0;
}

// Lua: refresh([win]). Shows the window on the terminal.
static int l_refresh(lua_State* const L)
{
    WINDOW* const win = optwindow(L, 1);

    if (ERR == wrefresh(win))
    {
        return luaL_error(L, "refresh: ncurses error");
    }
    colorpairs_next_frame();
    return 0;
}

// Lua: noutrefresh([win]). Copies the window to the virtual screen, for
// doupdate to show; raises "wnoutrefresh: ncurses error".
static int l_noutrefresh(lua_State* const L)
{
    WINDOW* const win = optwindow(L, 1);

    if (ERR == wnoutrefresh(win))
    {
        return luaL_error(L, "wnoutrefresh: ncurses error");
    }
    return 0;
}

// The WA_* attributes at arg, which must fit attr_t: raises an argument
// error rather than let a value wrap
static attr_t checkattrs(lua_State* const L, int const arg)
{
    lua_Integer const a = luaL_checkinteger(L, arg);
    luaL_argcheck(L, 0 <= a && (lua_Unsigned)a <= (attr_t)-1, arg, "out of range");
    return (attr_t)a;
}

// Lua: attron(attrs, [win]). Turns on the WA_* attributes in attrs; raises
// an argument error when attrs doesn't fit attr_t, and "wattr_on: ncurses
// error".
static int l_attron(lua_State* const L)
{
    attr_t const a = checkattrs(L, 1);
    WINDOW* const win = optwindow(L, 2);

    if (ERR == wattr_on(win, a, NULL))
    {
        return luaL_error(L, "wattr_on: ncurses error");
    }
    return 0;
}

// Lua: attroff(attrs, [win]). Turns off the WA_* attributes in attrs;
// raises an argument error when attrs doesn't fit attr_t, and "wattr_off:
// ncurses error".
static int l_attroff(lua_State* const L)
{
    attr_t const a = checkattrs(L, 1);
    WINDOW* const win = optwindow(L, 2);

    if (ERR == wattr_off(win, a, NULL))
    {
        return luaL_error(L, "wattr_off: ncurses error");
    }
    return 0;
}

// Lua: attrget([win]) -> attrs, pair. The window's attributes and color
// pair, for attrset to restore; raises "wattr_get: ncurses error".
static int l_attrget(lua_State* const L)
{
    WINDOW* const win = optwindow(L, 1);

    attr_t attrs;
    short short_pair;
    int colorpair;
    if (ERR == wattr_get(win, &attrs, &short_pair, &colorpair))
    {
        return luaL_error(L, "wattr_get: ncurses error");
    }

    lua_pushinteger(L, attrs);
    lua_pushinteger(L, colorpair);
    return 2;
}

// Lua: attrset(attrs, pair, [win]). Sets the attributes and color pair, as
// attrget returns them; attrs must fit attr_t and pair be 0 to
// COLOR_PAIRS - 1. Raises "wattr_set: ncurses error".
static int l_attrset(lua_State* const L)
{
    attr_t const a = checkattrs(L, 1);
    lua_Integer const color = luaL_checkinteger(L, 2);
    luaL_argcheck(L, 0 <= color && color < COLOR_PAIRS, 2, "out of range");
    WINDOW* const win = optwindow(L, 3);

    // the pair through opts, as pairs above 32767 don't fit the short
    int pair = (int)color;
    if (ERR == wattr_set(win, a, 0, &pair))
    {
        return luaL_error(L, "wattr_set: ncurses error");
    }
    return 0;
}

// Lua: addstr(...). Writes each string argument in turn at stdscr's
// cursor, ignoring ncurses errors.
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

// Lua: mvaddstr(y, x, ...). Moves stdscr's cursor and writes each string
// argument in turn, ignoring ncurses errors. Does nothing, not even check
// the strings, when (y, x) is outside stdscr.
static int l_mvaddstr(lua_State* const L)
{
    lua_Integer const y = luaL_checkinteger(L, 1);
    lua_Integer const x = luaL_checkinteger(L, 2);
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

// Lua: getyx([win]) -> y, x. The window's cursor, 0-based.
static int l_getyx(lua_State* const L)
{
    WINDOW* const win = optwindow(L, 1);

    int y, x;
    getyx(win, y, x);
    lua_pushinteger(L, y);
    lua_pushinteger(L, x);
    return 2;
}

// Lua: getmaxyx([win]) -> lines, columns. The window's size.
static int l_getmaxyx(lua_State* const L)
{
    WINDOW* const win = optwindow(L, 1);

    int y, x;
    getmaxyx(win, y, x);
    lua_pushinteger(L, y);
    lua_pushinteger(L, x);
    return 2;
}

// Lua: doupdate(). Shows the virtual screen on the terminal.
static int l_doupdate(lua_State* const L)
{
    if (ERR == doupdate())
    {
        return luaL_error(L, "doupdate: ncurses error");
    }
    colorpairs_next_frame();
    return 0;
}

// Lua: colorset([fore], [back], [win]). Sets the window's colors, each -1
// (the default, when nil or absent) to COLORS - 1, with a pair from
// colorpairs_get; when no pair can be had, the colors are the defaults
// without error. Raises "color_set: ncurses error".
static int l_colorset(lua_State* const L)
{
    lua_Integer const fore = luaL_optinteger(L, 1, -1);
    luaL_argcheck(L, -1 <= fore && fore < COLORS, 1, "out of range");

    lua_Integer const back = luaL_optinteger(L, 2, -1);
    luaL_argcheck(L, -1 <= back && back < COLORS, 2, "out of range");

    WINDOW* const win = optwindow(L, 3);

    int pair = fore < 0 && back < 0 ? 0 : colorpairs_get(fore, back);

    // the pair through opts, as pairs above 32767 don't fit the short
    if (ERR == wcolor_set(win, 0, &pair))
    {
        return luaL_error(L, "color_set: ncurses error");
    }

    return 0;
}

// Lua: move(y, x, [win]). Moves the cursor, 0-based; raises "move" when
// that is outside the window.
static int l_move(lua_State* const L)
{
    int const y = checkint(L, 1);
    int const x = checkint(L, 2);
    WINDOW* const win = optwindow(L, 3);
    if (ERR == wmove(win, y, x))
    {
        return luaL_error(L, "move");
    }
    return 0;
}

// Lua: cursset(visibility) -> previous. Cursor visibility: 0 invisible,
// 1 normal, 2 very visible. Raises "curs_set: invalid argument" when the
// value or the terminal doesn't allow it.
static int l_cursset(lua_State* const L)
{
    int const visibility = checkint(L, 1);
    int previous = curs_set(visibility);
    if (previous == ERR)
    {
        return luaL_error(L, "curs_set: invalid argument");
    }
    lua_pushinteger(L, previous);
    return 1;
}

// Lua: flash(). Flashes the screen, or beeps if the terminal can't.
static int l_flash(lua_State* const L)
{
    flash();
    return 0;
}

// Lua: beep(). Beeps, or flashes the screen if the terminal can't.
static int l_beep(lua_State* const L)
{
    beep();
    return 0;
}

// Functions of the module table
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

// CCR(n, v) sets field n of the table on top of the stack to the integer v;
// CC(s) names the field after the constant s, CF(i) as "KEY_F<i>".
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
    CC(COLORS); // 2^24 for direct color, where a color is 0xRRGGBB

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
