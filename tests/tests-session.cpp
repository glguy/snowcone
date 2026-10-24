// Integration test for the Lua-facing IRC session (client/irc/lua.cpp):
// real Lua, real connection machinery, and a local TCP server.
//
// Checks the callback contract around local close():
//  * a callback that closes the connection gets no further events
//  * the session ends normally (END with nil) rather than with a read error
//  * once a session ends the connection is closed, even with a write in flight

#include "app.hpp"
#include "irc/lua.hpp"
#include "safecall.hpp"

#include <pkey.hpp>
#include <x509.hpp>

extern "C" {
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
}

#include <boost/asio.hpp>

#include <functional>
#include <iostream>
#include <memory>
#include <string>

// ---- stand-ins for pieces that need ncurses / the real OpenSSL bindings

static char const app_key = '\0';

App::App(char const* const filename)
    : io_context{}
    , stdin_poll{io_context}
    , signals{io_context}
    , main_source{filename}
{
    L = luaL_newstate();
    luaL_openlibs(L);
    lua_pushlightuserdata(L, this);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &app_key);
}

App::~App()
{
    lua_close(L);
}

auto App::from_lua(lua_State* const L) -> App*
{
    lua_rawgetp(L, LUA_REGISTRYINDEX, &app_key);
    auto const a = static_cast<App*>(lua_touserdata(L, -1));
    lua_pop(L, 1);
    return a;
}

namespace myopenssl {
auto check_x509(lua_State*, int) -> X509* { return nullptr; }
auto check_pkey(lua_State*, int) -> EVP_PKEY* { return nullptr; }
} // namespace myopenssl

int safecall(lua_State* const L, std::string_view const location, int const args)
{
    lua_pushcfunction(L, [](auto const L) {
        auto const msg = luaL_tolstring(L, 1, nullptr);
        luaL_traceback(L, L, msg, 1);
        return 1;
    });
    lua_insert(L, -2 - args);
    auto const status = lua_pcall(L, args, 0, -2 - args);
    if (LUA_OK == status)
    {
        lua_pop(L, 1);
    }
    else
    {
        std::cerr << "error in " << location << ": " << lua_tostring(L, -1) << std::endl;
        lua_pop(L, 2);
    }
    return status;
}

// ---- test scaffolding

namespace asio = boost::asio;
using tcp = asio::ip::tcp;

namespace {

struct Observed
{
    std::string received;
    bool server_saw_end = false;
};

using Sock = std::shared_ptr<tcp::socket>;

void read_until_end(Sock sock, std::shared_ptr<Observed> seen)
{
    auto buf = std::make_shared<std::array<char, 65536>>();
    sock->async_read_some(asio::buffer(*buf), [sock, seen, buf](boost::system::error_code ec, std::size_t n) {
        seen->received.append(buf->data(), n);
        if (ec)
        {
            seen->server_saw_end = true;
        }
        else
        {
            read_until_end(sock, seen);
        }
    });
}

struct Scenario
{
    char const* name;
    char const* lua;
    std::function<void(Sock, std::shared_ptr<Observed>)> server;
    char const* expected_events;
    std::function<bool(Observed const&)> check;
};

auto write_then(Sock sock, std::string data, std::function<void()> next) -> void
{
    auto text = std::make_shared<std::string>(std::move(data));
    asio::async_write(*sock, asio::buffer(*text), [sock, text, next = std::move(next)](auto, auto) { next(); });
}

auto const prelude = R"lua(
events = {}
local function log(s) events[#events + 1] = s end
)lua";

auto run(Scenario const& s) -> bool
{
    App app{"unused"};
    auto& io = app.get_context();
    auto const L = app.get_lua();

    tcp::acceptor acceptor{io, {asio::ip::make_address("127.0.0.1"), 0}};
    auto const port = acceptor.local_endpoint().port();
    auto const seen = std::make_shared<Observed>();

    auto sock = std::make_shared<tcp::socket>(io);
    acceptor.async_accept(*sock, [&](boost::system::error_code ec) {
        if (!ec)
        {
            s.server(sock, seen);
        }
    });

    lua_pushcfunction(L, l_start_irc);
    lua_setglobal(L, "connect");
    lua_pushinteger(L, port);
    lua_setglobal(L, "port");

    auto const script = std::string{prelude} + s.lua;
    if (luaL_dostring(L, script.c_str()) != LUA_OK)
    {
        std::cerr << s.name << ": script error: " << lua_tostring(L, -1) << "\n";
        return false;
    }

    // run() returns once every operation has finished; the time limit only
    // keeps a hung scenario from hanging the test.
    io.run_for(std::chrono::seconds(15));
    bool const timed_out = !io.stopped();

    lua_getglobal(L, "events");
    std::string events;
    for (lua_Integer i = 1; lua_geti(L, -1, i) != LUA_TNIL; ++i)
    {
        if (i > 1)
            events += ',';
        events += lua_tostring(L, -1);
        lua_pop(L, 1);
    }
    lua_pop(L, 2);

    bool ok = !timed_out && events == s.expected_events && s.check(*seen);
    std::cout << (ok ? "PASS " : "FAIL ") << s.name << "  events=[" << events << "]"
              << (timed_out ? " (timed out)" : "") << "\n";
    if (!ok && events != s.expected_events)
    {
        std::cout << "     expected [" << s.expected_events << "]\n";
    }
    return ok;
}

} // namespace

int main()
{
    auto const any = [](Observed const&) { return true; };
    bool ok = true;

    ok &= run({
        "messages then peer closes",
        R"lua(
conn = connect('127.0.0.1', port, {}, function(ev, a, b)
  if ev == 'MSG' then log('MSG:' .. a.command) else log(ev .. (ev == 'END' and (':' .. tostring(a):sub(1, 11)) or '')) end
end)
)lua",
        [](Sock sock, auto) {
            write_then(sock, "PING :a\r\nPING :b\r\n", [sock] { sock->close(); });
        },
        "CON,MSG:PING,MSG:PING,END:End of file",
        any,
    });

    ok &= run({
        "close inside CON gets a clean end",
        R"lua(
conn = connect('127.0.0.1', port, {}, function(ev, a)
  if ev == 'CON' then log('CON'); conn:close()
  elseif ev == 'END' then log('END:' .. tostring(a))
  else log(ev) end
end)
)lua",
        [](Sock sock, auto seen) { read_until_end(sock, seen); },
        "CON,END:nil",
        [](Observed const& o) { return o.server_saw_end; },
    });

    ok &= run({
        "close inside MSG drops the rest of the batch",
        R"lua(
conn = connect('127.0.0.1', port, {}, function(ev, a)
  if ev == 'MSG' then log('MSG'); conn:close()
  elseif ev == 'END' then log('END:' .. tostring(a))
  else log(ev) end
end)
)lua",
        [](Sock sock, auto seen) {
            write_then(sock, "PING :a\r\nPING :b\r\nPING :c\r\n", [sock, seen] { read_until_end(sock, seen); });
        },
        "CON,MSG,END:nil",
        [](Observed const& o) { return o.server_saw_end; },
    });

    ok &= run({
        "connection is closed when a session ends with a write in flight",
        R"lua(
conn = connect('127.0.0.1', port, {}, function(ev, a)
  if ev == 'CON' then
    log('CON')
    conn:send(string.rep('A', 4 * 1024 * 1024)) -- more than the socket buffers hold
  elseif ev == 'END' then
    log('END:' .. tostring(a))
    conn:send('LATE\r\n')   -- must not reach the server
  else log(ev) end
end)
)lua",
        [](Sock sock, auto seen) {
            // an endless line fills the client's line buffer and ends the session
            write_then(sock, std::string(140'000, 'y'), [sock, seen] { read_until_end(sock, seen); });
        },
        "CON,END:line buffer full",
        [](Observed const& o) {
            return o.server_saw_end && o.received.find("LATE") == std::string::npos;
        },
    });

    std::cout << (ok ? "all passed\n" : "FAILURES\n");
    return ok ? 0 : 1;
}
