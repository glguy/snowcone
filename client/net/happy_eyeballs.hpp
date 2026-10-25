#pragma once

#include <boost/asio.hpp>

#include <functional>
#include <mutex>
#include <string>
#include <utility>

namespace happy_eyeballs {

/**
 * @brief Thread-safe, sticky cancellation source for one in-flight connect.
 *
 * - Supports a single registered handler, so at most one operation may use a
 *   source at a time.
 * - Cancellation is sticky: once emitted, later operations that use the same
 *   source complete immediately with operation_aborted.
 * - Emitted types accumulate (bitwise OR), so a later partial cancellation
 *   never downgrades an earlier terminal one.
 * - The handler is invoked while an internal mutex is held. It must not call
 *   back into this object; the handler used by async_connect only posts work.
 */
class CancellationSource
{
    boost::asio::cancellation_signal signal_;
    std::mutex mutex_;
    boost::asio::cancellation_type cancelled_ = boost::asio::cancellation_type::none;

public:
    /**
     * Registers handler and returns the cancellation type already emitted
     * (none if the source has not been cancelled). The handler is not invoked
     * for a cancellation that happened before registration; callers must act
     * on the returned value instead.
     */
    auto assign(std::function<void(boost::asio::cancellation_type)> handler) -> boost::asio::cancellation_type
    {
        std::lock_guard lock{mutex_};
        signal_.slot().assign(std::move(handler));
        return cancelled_;
    }

    /// Remove the registered handler, whichever operation registered it.
    auto clear() -> void
    {
        std::lock_guard lock{mutex_};
        signal_.slot().clear();
    }

    auto emit(boost::asio::cancellation_type type) -> void
    {
        std::lock_guard lock{mutex_};
        if (type != boost::asio::cancellation_type::none)
        {
            cancelled_ = cancelled_ | type;
        }
        signal_.emit(type);
    }
};

/**
 * @brief Resolve a host and connect using staggered IPv6/IPv4 attempts.
 *
 * The socket must be unopened; an open socket fails with
 * boost::asio::error::already_open. Attempts use fresh sockets, so options or
 * bindings set on socket before this call are not preserved. Every attempt
 * socket is created close-on-exec, so no descriptor opened here can leak into
 * a spawned process. On success, the winning socket is move-assigned into
 * socket on the caller's executor and its endpoint is returned.
 *
 * Errors are delivered through the awaitable and are thrown by co_await as
 * boost::system::system_error. Cancellation (through the coroutine's
 * cancellation state or close_cancellation) completes with operation_aborted.
 * Every cancellation type other than none (terminal, partial or total) is
 * treated as terminal: the whole operation is abandoned. That is safe because
 * abandoning it has no side effects beyond closing the attempt sockets.
 *
 * Threading: as with any Asio operation, cancellation delivered through the
 * coroutine's own cancellation slot (co_spawn / cancel_after / awaitable
 * operators) must be emitted from, or serialized with, the coroutine's
 * executor, because the slot is assigned and cleared there and
 * boost::asio::cancellation_signal is not thread-safe. To cancel from an
 * arbitrary thread, use close_cancellation, which is mutex-protected.
 *
 * Cancellation completes the operation promptly, but an OS resolver blocked
 * in getaddrinfo may retain internal operation state until that call returns.
 */
auto async_connect(
    boost::asio::ip::tcp::socket& socket,
    std::string host,
    std::string service,
    CancellationSource& close_cancellation
) -> boost::asio::awaitable<boost::asio::ip::tcp::endpoint>;

}
