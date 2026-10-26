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
#include <thread>
#include <vector>

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
        // Scenarios see failed callbacks as an "error" event
        if (lua_getglobal(L, "events") == LUA_TTABLE)
        {
            lua_pushliteral(L, "error");
            lua_rawseti(L, -2, luaL_len(L, -2) + 1);
        }
        lua_pop(L, 1);
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

// F-001: a connection closed from outside its own callback, here from another
// connection's MSG callback, must get no further events, even when its read
// completion is already queued. The server writes to both connections in one
// handler, so both reads complete in the same poll; whichever MSG callback
// runs first closes both.
auto close_with_completion_queued() -> bool
{
    App app{"unused", true};
    auto& io = app.get_context();
    auto const L = app.get_lua();

    tcp::acceptor acceptor{io, {asio::ip::make_address("127.0.0.1"), 0}};
    std::vector<Sock> socks;
    asio::steady_timer delay{io};
    std::function<void()> accept_next = [&] {
        auto sock = std::make_shared<tcp::socket>(io);
        acceptor.async_accept(*sock, [&, sock](boost::system::error_code ec) {
            if (ec)
            {
                return;
            }
            socks.push_back(sock);
            if (socks.size() < 2)
            {
                accept_next();
                return;
            }
            // let both clients get CON and start reading first
            delay.expires_after(std::chrono::milliseconds(200));
            delay.async_wait([&](boost::system::error_code) {
                for (auto const& s : socks)
                {
                    boost::system::error_code ignored;
                    asio::write(*s, asio::buffer(std::string_view{"PING :x\r\n"}), ignored);
                }
                // loopback delivery isn't instant: give the kernel time to make
                // both client sockets readable before the next poll, so both
                // reads complete together
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            });
        });
    };
    accept_next();

    lua_pushcfunction(L, l_start_irc);
    lua_setglobal(L, "connect");
    lua_pushinteger(L, acceptor.local_endpoint().port());
    lua_setglobal(L, "port");

    auto const script = std::string{prelude} + R"lua(
local conns = {}
local function handler(ev, a)
  if ev == 'MSG' then
    log('MSG')
    for _, c in ipairs(conns) do c:close() end
  elseif ev == 'END' then log('END:' .. tostring(a))
  end
end
conns[1] = connect('127.0.0.1', port, {}, handler)
conns[2] = connect('127.0.0.1', port, {}, handler)
)lua";
    if (luaL_dostring(L, script.c_str()) != LUA_OK)
    {
        std::cerr << "close with completion queued: script error: " << lua_tostring(L, -1) << "\n";
        return false;
    }

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

    auto const expected = "MSG,END:nil,END:nil";
    bool const ok = !timed_out && events == expected;
    std::cout << (ok ? "PASS " : "FAIL ") << "close with a read completion queued  events=[" << events << "]"
              << (timed_out ? " (timed out)" : "") << "\n";
    if (!ok)
    {
        std::cout << "     expected [" << expected << "]\n";
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
        "handle methods report a locally closed connection",
        R"lua(
local function try(name, ...)
  local ok, err = ...
  log(name .. ':' .. tostring(ok) .. (err and (':' .. err) or ''))
end
conn = connect('127.0.0.1', port, {}, function(ev, a)
  if ev == 'CON' then
    try('send', conn:send('x\r\n'))
    try('close', conn:close())
    try('send', conn:send('y\r\n'))
    try('close', conn:close())
  elseif ev == 'END' then log('END:' .. tostring(a))
  else log(ev) end
end)
)lua",
        [](Sock sock, auto seen) { read_until_end(sock, seen); },
        "send:true,close:true,send:nil:connection closed,close:nil:connection closed,END:nil",
        [](Observed const& o) { return o.received.find('y') == std::string::npos; },
    });

    ok &= run({
        "send after the server ends the session reports it closed",
        R"lua(
conn = connect('127.0.0.1', port, {}, function(ev, a)
  if ev == 'END' then
    local ok, err = conn:send('LATE\r\n')
    log('END,send:' .. tostring(ok) .. ':' .. tostring(err))
  else log(ev) end
end)
)lua",
        [](Sock sock, auto) { sock->close(); },
        "CON,END,send:nil:connection closed",
        any,
    });

    ok &= close_with_completion_queued();

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
    ok &= check_arguments(args("{ {type = 'tls', alpn = 'irc'} }").c_str(), "'alpn' must be a list of protocol names");
    ok &= check_arguments(args("{ {type = 'tls', alpn = {''}} }").c_str(), "'alpn' must be a list of protocol names");
    ok &= check_arguments(args("{ {type = 'tls', alpn = {string.rep('x', 256)}} }").c_str(), "'alpn' must be a list of protocol names");
    ok &= check_arguments(args("{ {type = 'tls', alpn = {irc = true}} }").c_str(), "'alpn' must be a list of protocol names");
    ok &= check_arguments(args("{ {type = 'tls', alpn = {'irc', 7}} }").c_str(), "'alpn' must be a list of protocol names");
    ok &= check_accepted(args("{ {type = 'tls', alpn = {'irc', string.rep('x', 255)}} }").c_str());
    ok &= check_accepted(args("{ {type = 'tls', alpn = {}} }").c_str());
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
    ok &= check_arguments("'/bin/true', {'a', {}}, function() end", "argument 2 is a table, not a string", "execute");
    ok &= check_arguments("'/bin/true', {'a', true}, function() end", "argument 2 is a boolean, not a string", "execute");
    ok &= check_arguments(
        "'/bin/true', {setmetatable({}, {__tostring = function() return 'x' end})}, function() end",
        "argument 1 is a table, not a string", "execute");
    ok &= check_arguments(
        "'/bin/true', (function() local t = {} for i = 1, 65537 do t[i] = 'x' end return t end)(), function() end",
        "too many arguments", "execute");
    ok &= run({
        "execute returns a handle and converts numbers, ignoring __len",
        R"lua(
local args = setmetatable({1, 'x'}, {__len = function() return 0 end})
log(type(execute('/bin/echo', args, function(code, out)
  log(code .. ':' .. (out:gsub('\n', '')))
end)))
)lua",
        nullptr,
        "userdata,0:1 x",
        any,
    });

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

    // F-063: a wait whose success completion is already queued, when a
    // callback that runs first cancels or restarts that timer. Timers that
    // expire together complete in the same poll.
    ok &= run({
        "cancel after the completion is queued",
        R"lua(
local a, b = newtimer(), newtimer()
a:start(0, function() log('a') b:cancel() end)
b:start(0, function() log('b') end)
)lua",
        nullptr,
        "a",
        any,
    });
    ok &= run({
        "restart after the completion is queued",
        R"lua(
local a, b = newtimer(), newtimer()
a:start(0, function()
  log('a')
  b:start(100, function() log('b2') end)
  a:start(20, function() log('a2') end)
end)
b:start(0, function() log('b1') end)
)lua",
        nullptr,
        "a,a2,b2",
        any,
    });
    // A collected timer's queued completion must not run anything, even if
    // a new timer reuses its memory
    ok &= run({
        "collect after the completion is queued",
        R"lua(
local a = newtimer()
b, cs = newtimer(), {}
a:start(0, function()
  log('a')
  b = nil
  collectgarbage()
  collectgarbage()
  local fired = 0
  for i = 1, 100 do
    cs[i] = newtimer()
    cs[i]:start(100, function()
      fired = fired + 1
      if fired == 100 then log('c') end
    end)
  end
end)
b:start(0, function() log('b') end)
)lua",
        nullptr,
        "a,c",
        any,
    });

    // F-013: a wait started from a coroutine fires on the main thread after
    // that coroutine is gone
    ok &= run({
        "timer started from a collected coroutine",
        R"lua(
local t = newtimer()
coroutine.wrap(function()
  t:start(20, function() log(tostring(select(2, coroutine.running()))) end)
end)()
collectgarbage()
collectgarbage()
)lua",
        nullptr,
        "true",
        any,
    });

    // F-064: the metatable is hidden, and a timer reached after its
    // finalizer ran (here resurrected by another finalizer) is inert
    ok &= run({
        "finalized timer",
        R"lua(
log(tostring(getmetatable(newtimer())))
do
  local t = newtimer()
  t:start(0, function() log('fired') end)
  setmetatable({}, {__gc = function() kept = t end})
end
collectgarbage()
collectgarbage()
kept:cancel()
kept:cancel()
local ok, err = pcall(kept.start, kept, 0, function() log('restarted') end)
log(tostring(ok) .. ':' .. err)
)lua",
        nullptr,
        "false,false:start: timer is finalized",
        any,
    });

    std::cout << (ok ? "all passed\n" : "FAILURES\n");
    return ok ? 0 : 1;
}
