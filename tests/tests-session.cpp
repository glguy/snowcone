// Integration test for the Lua-facing IRC session (client/irc/lua.cpp):
// real Lua, real connection machinery, and a local TCP server.
//
// Checks the callback contract around local close():
//  * a callback that closes the connection gets no further events
//  * the session ends normally (END with nil) rather than with a read error
//  * once a session ends the connection is closed, even with a write in flight

#include "app.hpp"
#include "irc/lua.hpp"
#include "process.hpp"
#include "safecall.hpp"
#include "timer.hpp"

#include <myopenssl.hpp>

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

App::App(char const* const filename, bool const headless)
    : io_context{}
    , stdin_poll{io_context}
    , signals{io_context}
    , main_source{filename}
    , headless{headless}
{
    L = luaL_newstate();
    luaL_openlibs(L);
    luaL_requiref(L, "myopenssl", luaopen_myopenssl, 1);
    lua_pop(L, 1);
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
    App app{"unused", true};
    auto& io = app.get_context();
    auto const L = app.get_lua();

    tcp::acceptor acceptor{io, {asio::ip::make_address("127.0.0.1"), 0}};
    auto const port = acceptor.local_endpoint().port();
    auto const seen = std::make_shared<Observed>();

    auto sock = std::make_shared<tcp::socket>(io);
    if (s.server) // scenarios that don't connect have no server side
    {
        acceptor.async_accept(*sock, [&](boost::system::error_code ec) {
            if (!ec)
            {
                s.server(sock, seen);
            }
        });
    }

    lua_pushcfunction(L, l_start_irc);
    lua_setglobal(L, "connect");
    lua_pushcfunction(L, l_execute);
    lua_setglobal(L, "execute");
    lua_pushcfunction(L, l_new_timer);
    lua_setglobal(L, "newtimer");
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

// Helpers for argument scripts: cert() is a certificate for key(), and
// other_key() is any other key
char const* const tls_prelude = R"lua(
local k = myopenssl.gen_pkey('EC', 'P-256')
function key() return k end
function other_key() return myopenssl.gen_pkey('EC', 'P-256') end
function cert()
  local x = myopenssl.new_x509()
  x:set_pubkey(k)
  x:sign(k)
  return x
end
)lua";

// Bad arguments must raise a Lua error before anything is started. A missing
// layer `type` used to dereference a null pointer, and an unknown one was
// silently skipped.
auto check_arguments(char const* const args, char const* const expected_error, char const* const fn = "connect") -> bool
{
    App app{"unused", true};
    auto const L = app.get_lua();
    lua_pushcfunction(L, l_start_irc);
    lua_setglobal(L, "connect");
    lua_pushcfunction(L, l_execute);
    lua_setglobal(L, "execute");

    auto const script = std::string{tls_prelude} + "local ok, err = pcall(" + fn + ", " + args
        + "); return ok, tostring(err)";
    if (luaL_dostring(L, script.c_str()) != LUA_OK)
    {
        std::cout << "FAIL arguments " << args << ": script error: " << lua_tostring(L, -1) << "\n";
        return false;
    }
    bool const raised = !lua_toboolean(L, -2);
    std::string const message = lua_tostring(L, -1);
    bool const ok = raised && message.find(expected_error) != std::string::npos;
    std::cout << (ok ? "PASS " : "FAIL ") << "arguments " << args << "  -> " << message << "\n";
    return ok;
}

// Arguments that must not raise. The connection is never run.
auto check_accepted(char const* const args) -> bool
{
    App app{"unused", true};
    auto const L = app.get_lua();
    lua_pushcfunction(L, l_start_irc);
    lua_setglobal(L, "connect");

    auto const script = std::string{tls_prelude} + "local ok, err = pcall(connect, " + args
        + "); if ok then err:close() end; return ok, tostring(err)";
    if (luaL_dostring(L, script.c_str()) != LUA_OK)
    {
        std::cout << "FAIL accepted " << args << ": script error: " << lua_tostring(L, -1) << "\n";
        return false;
    }
    bool const ok = lua_toboolean(L, -2);
    std::cout << (ok ? "PASS " : "FAIL ") << "accepted " << args << "  -> " << lua_tostring(L, -1) << "\n";
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

    ok &= run({
        "valid layer table is accepted",
        R"lua(
conn = connect('127.0.0.1', port, {{type = 'socks', host = 'proxy.invalid', port = 1080}}, function(ev)
  log(ev)
end)
)lua",
        [](Sock sock, auto) { sock->close(); },
        "END",
        any,
    });

    auto const cb = "function() end";
    auto const args = [&](std::string layers, std::string port = "6667") {
        return "'host', " + port + ", " + layers + ", " + cb;
    };
    ok &= check_arguments(args("{ {} }").c_str(), "missing or non-string 'type'");
    ok &= check_arguments(args("{ {type = 7} }").c_str(), "missing or non-string 'type'");
    ok &= check_arguments(args("{ {type = 'tsl'} }").c_str(), "unknown type 'tsl'");
    ok &= check_arguments(args("{ 'tls' }").c_str(), "must be a table");
    ok &= check_arguments(args("nil").c_str(), "table expected");
    ok &= check_arguments(args("{}", "70000").c_str(), "port out of range");
    ok &= check_arguments(args("{}", "-1").c_str(), "port out of range");
    ok &= check_arguments(args("{ {type = 'socks', host = 'h'} }").c_str(), "'port' must be an integer");
    ok &= check_arguments(args("{ {type = 'socks', host = 'h', port = 0} }").c_str(), "'port' must be an integer");
    ok &= check_arguments(args("{ {type = 'http', host = 'h', port = 65536} }").c_str(), "'port' must be an integer");
    ok &= check_arguments(args("{ {type = 'socks', port = 1080} }").c_str(), "'host' must be a string");
    ok &= check_arguments(args("{ {type = 'socks', host = 'h', port = 1080, username = 'u'} }").c_str(), "'username' and 'password' must be given together");
    ok &= check_arguments(args("{ {type = 'http', host = 'h', port = 8080, password = 'p'} }").c_str(), "'username' and 'password' must be given together");
    ok &= check_arguments(args("{ {type = 'socks', host = 'h', port = 1080, username = 'u', password = 7} }").c_str(), "'password' must be a string");
    // Hosts and types reach C APIs, so a NUL is refused instead of truncating
    ok &= check_arguments(args("{ {type = 'tls\\0junk'} }").c_str(), "missing or non-string 'type'");
    ok &= check_arguments(args("{ {type = 'socks', host = 'h\\0x', port = 1080} }").c_str(), "'host' must be a string without NUL bytes");
    ok &= check_arguments("'irc.example\\0x', 6667, {}, function() end", "contains a NUL byte");
    // Credentials are sent with their lengths, so they may hold any bytes
    ok &= check_accepted(args("{ {type = 'socks', host = 'h', port = 1, username = 'u\\0v', password = 'p\\0q'} }").c_str());
    ok &= check_arguments(args("{ {type = 'tls', sni = 5} }").c_str(), "'sni' must be a string");
    ok &= check_arguments(args("{ {type = 'tls', verify = {}} }").c_str(), "'verify' must be a string");
    // Client certificates: cert() is signed by key(), and other_key() isn't
    auto const tls_with = [&](std::string fields) {
        return args("{ {type = 'tls', " + fields + "} }");
    };
    ok &= check_arguments(tls_with("client_cert = cert()").c_str(), "must be given together");
    ok &= check_arguments(tls_with("client_key = key()").c_str(), "must be given together");
    ok &= check_arguments(tls_with("client_cert = cert(), client_key = other_key()").c_str(), "does not match");
    ok &= check_arguments(tls_with("client_cert = {}, client_key = key()").c_str(), "'client_cert' must be an open x509");
    ok &= check_arguments(tls_with("client_cert = cert(), client_key = 'pem'").c_str(), "'client_key' must be an open pkey");
    ok &= check_arguments(
        "'host', 6667, (function() local c = cert(); getmetatable(c).__close(c); return { {type = 'tls', client_cert = c, client_key = key()} } end)(), function() end",
        "'client_cert' must be an open x509");
    ok &= check_accepted(tls_with("client_cert = cert(), client_key = key()").c_str());
    ok &= check_arguments(args("{ {type = 'tls', verify = 'a\\0b'} }").c_str(), "without NUL bytes");
    ok &= check_arguments(args("{ {type = 'tls', sni = 'a\\0b'} }").c_str(), "without NUL bytes");
    ok &= check_arguments(args("{ {type = 'tls'} }", "0").c_str(), "requires 'verify'");
    ok &= check_arguments(args("{ {type = 'tls', sni = 'irc.example'} }", "0").c_str(), "requires 'verify'");
    ok &= check_accepted(args("{ {type = 'tls', verify = ''} }", "0").c_str());
    ok &= check_accepted(args("{ {type = 'tls', verify = 'irc.example'} }", "0").c_str());
    ok &= check_accepted(args("{ {type = 'socks', host = 'h', port = 1}, {type = 'tls'} }", "0").c_str());
    ok &= check_accepted(args("{ {type = 'socks', host = 'h', port = 1, username = 'u', password = 'p'} }").c_str());

    // snowcone.execute
    ok &= run({
        "execute reports exit status and output",
        R"lua(
execute('/bin/sh', {'-c', 'echo out; echo err >&2; exit 3'}, function(code, out, err)
  log(code .. ':' .. (out:gsub('\n', '')) .. ':' .. (err:gsub('\n', '')))
end)
)lua",
        nullptr,
        "3:out:err",
        any,
    });
    ok &= check_arguments("'/bin/true', 5, function() end", "table expected", "execute");
    ok &= check_arguments(
        "'/bin/true', setmetatable({}, {__len = function() return -1 end}), function() end",
        "bad argument count", "execute");
    ok &= check_arguments(
        "'/bin/true', setmetatable({}, {__len = function() return 1 << 40 end}), function() end",
        "bad argument count", "execute");

    // snowcone.newtimer: an enormous delay must not overflow the clock
    // arithmetic, and a negative one fires immediately
    ok &= run({
        "timer delays are clamped",
        R"lua(
local never = newtimer()
never:start(math.maxinteger, function() log('never') end)
never:cancel()
local huge = newtimer()
huge:start(math.maxinteger, function() log('never') end)
huge:cancel()
local now = newtimer()
now:start(-5, function() log('fired') end)
)lua",
        nullptr,
        "fired",
        any,
    });

    std::cout << (ok ? "all passed\n" : "FAILURES\n");
    return ok ? 0 : 1;
}
