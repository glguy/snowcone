#include "app.hpp"

#include "applib.hpp"
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

    app* a = static_cast<app*>(handle->loop->data);

    int key;
    mbstate_t ps {};

    while(ERR != (key = getch()))
    {
        if (key == '\x1b') {
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
        } else if (key > 0xff) {
            a->do_keyboard(-key);
        } else if (isascii(key)) {
            a->do_keyboard(key);
        } else {
            char c = key;
            wchar_t code;
            size_t r = mbrtowc(&code, &c, 1, &ps);
            if (r < (size_t)-2) {
                a->do_keyboard(code);
            }
        }
    }
}

/* Window size changes ***********************************************/

void on_winch(uv_signal_t* handle, int signum)
{
    auto a = static_cast<app*>(handle->loop->data);
    endwin();
    refresh();
    a->set_window_size();
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

    to_lua(L);

    prepare_globals(L, cfg);
    load_logic(L, cfg->lua_filename);
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
    class R {
        uv_write_t write;
        lua_State* L;
        int ref;
    public:
        R(lua_State* L, int ref) : L(L), ref(ref) { write.data = this; }
        ~R() { luaL_unref(L, LUA_REGISTRYINDEX, ref); }
        uv_write_t *to_write() { return &write; }
        static R* from_write(uv_write_t* write) { return static_cast<R*>(write->data); }
    };
}

bool app::send_irc(char const* cmd, std::size_t n, int ref) {
    if (nullptr == irc) {
        luaL_unref(L, LUA_REGISTRYINDEX, ref);
        return false;
    }

    auto req = std::make_unique<R>(L, ref);
    uv_buf_t const buf = {const_cast<char*>(cmd), n};

    auto cb = [](uv_write_t* write, int status){ delete R::from_write(write); };
    bool success = 0 == uv_write(req->to_write(), irc, &buf, 1, cb);

    if (success) {
        req.release();
    }

    return success;
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
