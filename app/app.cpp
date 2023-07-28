#include "app.hpp"

#include "applib.hpp"
#include "bracketed_paste.hpp"
#include "configuration.hpp"
#include "uv.hpp"

#include <ircmsg.hpp>
#if HAS_GEOIP
#include <mygeoip.h>
#endif
#include <myncurses.h>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

#include <ncurses.h>

#include <cstdlib>
#include <cwchar>
#include <locale>
#include <memory>
#include <stdexcept>
#include <unistd.h>

namespace {

/* Main Input ********************************************************/

void on_stdin(uv_poll_t* handle, int status, int events)
{
    if (status != 0) return;

    auto const a = app::from_loop(handle->loop);

    for(int key; ERR != (key = getch());)
    {
        if (a->paste) {
            if (bracketed_paste::end_paste == key) {
                a->do_paste();
            } else {
                a->paste->push_back(key);
            }
        } else if (key == '\x1b') {
            key = getch();
            a->do_keyboard(ERR == key ? '\x1b' : -key);
        } else if (KEY_MOUSE == key) {
            MEVENT ev;
            getmouse(&ev);
            if (ev.bstate == BUTTON1_CLICKED)
            {
                a->do_mouse(ev.y, ev.x);
            }
        } else if (KEY_RESIZE == key) {
        } else if (bracketed_paste::start_paste == key) {
            a->paste = "";
        } else if (key > 0xff) {
            a->do_keyboard(-key);
        } else if (isascii(key)) {
            a->do_keyboard(key);
        } else {
            char const c = key;
            wchar_t code;
            size_t const r = mbrtowc(&code, &c, 1, &a->mbstate);
            if (r < (size_t)-2) {
                a->do_keyboard(code);
            }
        }
    }
}

/* Window size changes ***********************************************/

void on_winch(uv_signal_t* handle, int signum)
{
    endwin();
    refresh();
    app::from_loop(handle->loop)->set_window_size();
}

} // namespace

void app::init()
{
    uvok(uv_loop_init(&loop));
    uvok(uv_poll_init(&loop, &input, STDIN_FILENO));
    uvok(uv_signal_init(&loop, &winch));
    uvok(uv_timer_init(&loop, &reconnect));

    uvok(uv_poll_start(&input, UV_READABLE, on_stdin));
    uvok(uv_signal_start(&winch, on_winch, SIGWINCH));

    L = luaL_newstate();
    if (nullptr == L) throw std::runtime_error("failed to create lua");
    app_cell(L) = this;

    prepare_globals(L, cfg);
    load_logic(L, cfg.lua_filename);
}

void app::run() {
    uvok(uv_run(&loop, UV_RUN_DEFAULT));
}

void app::shutdown()
{
    closing = true;
    uv_close(handle_cast(&winch), nullptr);
    uv_close(handle_cast(&input), nullptr);
    uv_close(handle_cast(&reconnect), nullptr);
}

void app::destroy()
{
    lua_close(L);
    uvok(uv_loop_close(&loop));
}

void app::do_keyboard(long key)
{
    lua_pushinteger(L, key);
    lua_callback(L, "on_keyboard");
}

void app::do_paste()
{
    lua_pushlstring(L, paste->data(), paste->size());
    paste.reset();
    lua_callback(L, "on_paste");
}

void app::set_irc(uv_stream_t *irc)
{
    if (closing) {
        uv_close(handle_cast(irc), nullptr);
    } else {
        this->irc = irc;
        lua_callback(L, "on_connect");
    }
}

void app::clear_irc()
{
    irc = nullptr;
    lua_callback(L, "on_disconnect");
}

void app::set_window_size()
{
    l_ncurses_resize(L);
}

void app::do_irc(ircmsg const& msg)
{
    pushircmsg(L, msg);
    lua_callback(L, "on_irc");
}

bool app::close_irc() {
    if (nullptr == irc) {
        return false;
    }

    auto shutdown = std::make_unique<uv_shutdown_t>();
    uvok(uv_shutdown(shutdown.get(), irc, [](uv_shutdown_t* req, auto stat) {
        delete req;
    }));
    shutdown.release();

    irc = nullptr;
    return true;
}

namespace {
    class R final {
        uv_write_t write;
        lua_State* const L;
        int const ref;
    public:
        R(lua_State* L, int ref) : L{L}, ref{ref} {
            write.data = this;
        }
        ~R() {
            luaL_unref(L, LUA_REGISTRYINDEX, ref);
        }
        uv_write_t *to_write() {
            return &write;
        }
        static R* from_write(uv_write_t const* write) {
            return static_cast<R*>(write->data);
        }
    };
}

bool app::send_irc(char const* cmd, std::size_t n, int ref) {
    if (nullptr == irc) {
        luaL_unref(L, LUA_REGISTRYINDEX, ref);
        return false;
    }

    auto const buf = uv_buf_init(const_cast<char*>(cmd), n);
    auto req = std::make_unique<R>(L, ref);
    uvok(uv_write(req->to_write(), irc, &buf, 1,
        [](uv_write_t* write, int status){
            delete R::from_write(write);
        }));
    req.release();

    return true;
}

void app::do_irc_err(std::string_view msg)
{
    lua_pushlstring(L, msg.begin(), msg.size());
    lua_callback(L, "on_irc_err");
}

void app::do_mouse(int y, int x)
{
    lua_pushinteger(L, y);
    lua_pushinteger(L, x);
    lua_callback(L, "on_mouse");
}

std::chrono::seconds app::next_delay() {
    auto result = reconnect_delay;
    if (reconnect_delay < 10s) reconnect_delay += 5s;
    return result;
}

void app::reset_delay() {
    reconnect_delay = 0s;
}
