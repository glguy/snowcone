#include "timer.hpp"

#include "LuaRef.hpp"
#include "app.hpp"
#include "boundary.hpp"
#include "safecall.hpp"
#include "userdata.hpp"

extern "C" {
#include <lauxlib.h>
#include <lua.h>
}

#include <boost/asio/steady_timer.hpp>

#include <algorithm> // clamp
#include <chrono> // durations
#include <memory>
#include <optional>

namespace {

/// The callback of one start(), shared with that wait's completion handler,
/// and empty once disarmed. The handler holds no pointer to the userdata,
/// which may be collected, and its memory reused, while a completion is
/// queued.
///
/// The io_context destroys queued handlers only after lua_close, but no
/// LuaRef is left to unref by then: every armed Pending belongs to a live
/// timer, and lua_close runs each timer's __gc, which disarms it.
using Pending = std::optional<LuaRef>;

struct Timer
{
    std::optional<boost::asio::steady_timer> timer; // empty once finalized
    std::shared_ptr<Pending> pending; // the current wait, if any

    /// Drop the current wait's callback. A completion already queued for it
    /// then does nothing; cancel() alone can't stop one.
    auto disarm() -> void
    {
        if (pending)
        {
            pending->reset();
            pending.reset();
        }
    }
};

} // namespace

template <>
char const* const udata_name<Timer> = "steady_timer";

namespace {

/// About 31 years; far beyond any real delay, and small enough that
/// converting it to nanoseconds can't overflow.
constexpr lua_Integer max_delay_ms = 1'000'000'000'000;

/// The userdata stays reachable after finalization (resurrection, weak-keyed
/// tables), so this may not be the last use of it, and the payload is
/// emptied rather than destroyed.
auto l_gc(lua_State* const L) -> int
{
    auto const t = check_udata<Timer>(L, 1);
    t->disarm();
    t->timer.reset();
    return 0;
}

/// @param self
/// @param delay milliseconds
/// @param callback
auto l_start(lua_State* const L) -> int
{
    auto const t = check_udata<Timer>(L, 1);
    auto const start = luaL_checkinteger(L, 2);
    luaL_checkany(L, 3);
    lua_settop(L, 3);
    if (not t->timer)
    {
        return luaL_error(L, "start: timer is finalized");
    }

    t->disarm();
    auto const pending = std::make_shared<Pending>(LuaRef::create(L));
    t->pending = pending;

    // Clamp so the conversion to the clock's resolution can't overflow
    auto const delay = std::clamp<lua_Integer>(start, 0, max_delay_ms);
    t->timer->expires_after(std::chrono::milliseconds{delay});
    t->timer->async_wait([pending](auto const error) {
        if (not *pending)
        {
            return; // cancelled, restarted or collected
        }
        // Each wait fires once; the Lua object no longer refers to it
        auto const callback = std::move(**pending);
        pending->reset();
        if (not error)
        {
            callback.push();
            safecall(callback.get_lua(), "timer", 0);
        }
    });

    return 0;
}

/// Does nothing on a finalized timer, which has no wait to cancel
auto l_cancel(lua_State* const L) -> int
{
    auto const t = check_udata<Timer>(L, 1);
    t->disarm();
    if (t->timer)
    {
        t->timer->cancel();
    }
    return 0;
}

luaL_Reg const MT[]{
    {"__gc", boundary<l_gc>},
    {}
};

luaL_Reg const Methods[]{
    {"start", boundary<l_start>},
    {"cancel", boundary<l_cancel>},
    {}
};

} // namespace

auto l_new_timer(lua_State* const L) -> int
{
    auto const t = new_udata<Timer>(L, 0, [L] {
        // Build metatable the first time
        luaL_setfuncs(L, MT, 0);
        luaL_newlibtable(L, Methods);
        luaL_setfuncs(L, Methods, 0);
        lua_setfield(L, -2, "__index");
        // Keep __gc out of reach of Lua code
        lua_pushboolean(L, false);
        lua_setfield(L, -2, "__metatable");
    });
    std::construct_at(t)->timer.emplace(App::from_lua(L)->get_context());
    return 1;
}
