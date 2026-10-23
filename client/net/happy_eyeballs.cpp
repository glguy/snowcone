#include "happy_eyeballs.hpp"

#include "cloexec.hpp"

#include <boost/asio/bind_executor.hpp>
#include <boost/asio/dispatch.hpp>
#include <boost/asio/post.hpp>

#include <algorithm>
#include <chrono>
#include <deque>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

namespace {

namespace asio = boost::asio;
using tcp = asio::ip::tcp;

std::chrono::milliseconds constexpr attempt_delay{250};
std::chrono::milliseconds constexpr resolution_delay{50};

// "No records for this family" results, as opposed to real resolver failures.
auto is_name_not_found(boost::system::error_code const& error) -> bool
{
    return error == asio::error::host_not_found ||
           error == asio::error::no_data;
}

// Failures that say more about this host's local network setup than about the
// remote server, e.g. an instant failure from IPv6 on a machine without a
// default IPv6 route. They should not mask a more informative error.
auto is_local_unreachable(boost::system::error_code const& error) -> bool
{
    return error == asio::error::network_unreachable ||
           error == asio::error::network_down ||
           error == asio::error::host_unreachable ||
           error == asio::error::address_family_not_supported;
}

template <typename Handler>
struct ConnectOperation : std::enable_shared_from_this<ConnectOperation<Handler>>
{
    tcp::socket& socket_;
    asio::strand<asio::any_io_executor> strand_;
    tcp::resolver ipv4_resolver_;
    tcp::resolver ipv6_resolver_;
    asio::steady_timer timer_;
    asio::steady_timer resolution_timer_;
    Handler handler_;
    asio::cancellation_slot associated_cancellation_;
    happy_eyeballs::CancellationSource& close_cancellation_;
    std::string host_;
    std::string service_;
    std::deque<tcp::endpoint> ipv4_endpoints_;
    std::deque<tcp::endpoint> ipv6_endpoints_;
    std::vector<std::shared_ptr<tcp::socket>> attempts_;
    boost::system::error_code ipv4_resolve_error_;
    boost::system::error_code ipv6_resolve_error_;
    boost::system::error_code ipv4_connect_error_;
    boost::system::error_code ipv6_connect_error_;
    bool ipv4_resolved_ = false;
    bool ipv6_resolved_ = false;
    bool prefer_ipv6_ = true;
    bool timer_pending_ = false;
    bool stagger_elapsed_ = false;
    bool resolution_timer_pending_ = false;
    bool resolution_delay_elapsed_ = false;
    bool done_ = false;
    std::size_t active_attempts_ = 0;
    std::size_t timer_generation_ = 0;
    std::size_t resolution_timer_generation_ = 0;

    ConnectOperation(
        tcp::socket& socket,
        Handler handler,
        asio::cancellation_slot associated_cancellation,
        happy_eyeballs::CancellationSource& close_cancellation,
        std::string host,
        std::string service
    )
        : socket_{socket}
        , strand_{asio::make_strand(socket.get_executor())}
        , ipv4_resolver_{strand_}
        , ipv6_resolver_{strand_}
        , timer_{strand_}
        , resolution_timer_{strand_}
        , handler_{std::move(handler)}
        , associated_cancellation_{associated_cancellation}
        , close_cancellation_{close_cancellation}
        , host_{std::move(host)}
        , service_{std::move(service)}
    {
    }

    auto start() -> void
    {
        std::weak_ptr<ConnectOperation> weak = this->shared_from_this();

        // The coroutine's slot is owned by the caller's executor, so it is
        // assigned here (still on that executor) rather than on our strand.
        // The handler only posts to the strand.
        if (associated_cancellation_.is_connected())
        {
            associated_cancellation_.assign([weak](asio::cancellation_type const type) {
                if (type != asio::cancellation_type::none)
                {
                    if (auto self = weak.lock())
                    {
                        asio::post(self->strand_, [self] { self->cancel(); });
                    }
                }
            });
        }

        auto self = this->shared_from_this();
        asio::dispatch(strand_, [self] {
            self->start_on_strand();
        });
    }

    auto start_on_strand() -> void
    {
        std::weak_ptr<ConnectOperation> weak = this->shared_from_this();
        auto const close_cancelled = close_cancellation_.assign([weak](asio::cancellation_type const type) {
            if (type != asio::cancellation_type::none)
            {
                if (auto self = weak.lock())
                {
                    asio::post(self->strand_, [self] { self->cancel(); });
                }
            }
        });

        // assign() does not replay an earlier cancellation; act on it here.
        if (close_cancelled != asio::cancellation_type::none)
        {
            cancel();
            return;
        }

        // RFC 8305: send the AAAA query first.
        auto self = this->shared_from_this();
        ipv6_resolver_.async_resolve(
            tcp::v6(),
            host_,
            service_,
            asio::bind_executor(strand_, [self](boost::system::error_code const error, tcp::resolver::results_type results) {
                self->resolved(true, error, results);
            })
        );
        ipv4_resolver_.async_resolve(
            tcp::v4(),
            host_,
            service_,
            asio::bind_executor(strand_, [self](boost::system::error_code const error, tcp::resolver::results_type results) {
                self->resolved(false, error, results);
            })
        );
    }

    auto resolved(
        bool const ipv6,
        boost::system::error_code const error,
        tcp::resolver::results_type const& results
    ) -> void
    {
        if (done_)
        {
            return;
        }

        auto& endpoints = ipv6 ? ipv6_endpoints_ : ipv4_endpoints_;
        auto& family_resolved = ipv6 ? ipv6_resolved_ : ipv4_resolved_;
        auto& resolve_error = ipv6 ? ipv6_resolve_error_ : ipv4_resolve_error_;
        family_resolved = true;
        if (error)
        {
            resolve_error = error;
        }
        else
        {
            for (auto const& result : results)
            {
                // Some platforms (macOS) answer an AAAA query for an IPv4
                // literal with its v4-mapped form. The IPv4 query already
                // yields that address, so don't count it as an IPv6 endpoint.
                auto const address = result.endpoint().address();
                if (ipv6 && address.is_v6() && address.to_v6().is_v4_mapped())
                {
                    continue;
                }
                endpoints.push_back(result.endpoint());
            }
        }

        if (active_attempts_ == 0)
        {
            start_next();
        }
        else if (has_endpoints() && stagger_elapsed_)
        {
            start_next();
        }
        else if (has_endpoints() && not timer_pending_)
        {
            schedule_next();
        }
    }

    auto has_endpoints() const -> bool
    {
        return not ipv4_endpoints_.empty() || not ipv6_endpoints_.empty();
    }

    auto take_endpoint() -> std::optional<tcp::endpoint>
    {
        auto& preferred = prefer_ipv6_ ? ipv6_endpoints_ : ipv4_endpoints_;
        auto& alternate = prefer_ipv6_ ? ipv4_endpoints_ : ipv6_endpoints_;
        auto* source = not preferred.empty() ? &preferred : not alternate.empty() ? &alternate : nullptr;
        if (not source)
        {
            return {};
        }

        auto endpoint = source->front();
        source->pop_front();
        prefer_ipv6_ = not endpoint.address().is_v6();
        return endpoint;
    }

    auto start_next() -> void
    {
        if (done_)
        {
            return;
        }

        if (resolution_timer_pending_ && (ipv6_resolved_ || not ipv6_endpoints_.empty()))
        {
            ++resolution_timer_generation_;
            resolution_timer_pending_ = false;
            resolution_timer_.cancel();
        }
        if (
            active_attempts_ == 0 &&
            not ipv4_endpoints_.empty() &&
            ipv6_endpoints_.empty() &&
            not ipv6_resolved_ &&
            not resolution_delay_elapsed_
        )
        {
            if (not resolution_timer_pending_)
            {
                schedule_resolution_delay();
            }
            return;
        }

        if (timer_pending_)
        {
            ++timer_generation_;
            timer_pending_ = false;
            timer_.cancel();
        }

        auto const endpoint = take_endpoint();
        if (not endpoint)
        {
            if (active_attempts_ == 0 && ipv4_resolved_ && ipv6_resolved_)
            {
                finish_failure();
            }
            return;
        }

        stagger_elapsed_ = false;
        auto attempt = std::make_shared<tcp::socket>(socket_.get_executor());
        attempts_.push_back(attempt);
        ++active_attempts_;

        auto self = this->shared_from_this();

        // Open the socket close-on-exec so that neither the winner nor any
        // in-flight or losing attempt can leak into a spawned process.
        boost::system::error_code open_error;
        open_cloexec(*attempt, endpoint->protocol(), open_error);
        if (open_error)
        {
            // Report through the normal completion path, but not re-entrantly.
            asio::post(strand_, [self, attempt, endpoint = *endpoint, open_error] {
                self->attempt_finished(attempt, endpoint, open_error);
            });
        }
        else
        {
            attempt->async_connect(
                *endpoint,
                asio::bind_executor(strand_, [self, attempt, endpoint = *endpoint](boost::system::error_code const error) {
                    self->attempt_finished(attempt, endpoint, error);
                })
            );
        }

        if (has_endpoints() || not ipv4_resolved_ || not ipv6_resolved_)
        {
            schedule_next();
        }
    }

    auto schedule_next() -> void
    {
        auto const generation = ++timer_generation_;
        timer_pending_ = true;
        timer_.expires_after(attempt_delay);
        auto self = this->shared_from_this();
        timer_.async_wait([self, generation](boost::system::error_code const error) {
            if (error || generation != self->timer_generation_)
            {
                return;
            }
            self->timer_pending_ = false;
            self->stagger_elapsed_ = true;
            if (self->has_endpoints())
            {
                self->start_next();
            }
        });
    }

    auto schedule_resolution_delay() -> void
    {
        auto const generation = ++resolution_timer_generation_;
        resolution_timer_pending_ = true;
        resolution_timer_.expires_after(resolution_delay);
        auto self = this->shared_from_this();
        resolution_timer_.async_wait([self, generation](boost::system::error_code const error) {
            if (error || generation != self->resolution_timer_generation_)
            {
                return;
            }
            self->resolution_timer_pending_ = false;
            self->resolution_delay_elapsed_ = true;
            self->start_next();
        });
    }

    auto attempt_finished(
        std::shared_ptr<tcp::socket> const& attempt,
        tcp::endpoint const& endpoint,
        boost::system::error_code const error
    ) -> void
    {
        if (done_)
        {
            return;
        }

        --active_attempts_;
        if (not error)
        {
            finish({}, attempt, endpoint);
            return;
        }

        auto& connect_error = endpoint.address().is_v6() ? ipv6_connect_error_ : ipv4_connect_error_;
        if (not connect_error)
        {
            connect_error = error;
        }
        boost::system::error_code ignored;
        attempt->close(ignored);
        attempts_.erase(std::remove(attempts_.begin(), attempts_.end(), attempt), attempts_.end());
        if (has_endpoints())
        {
            start_next();
        }
        else if (active_attempts_ == 0 && ipv4_resolved_ && ipv6_resolved_)
        {
            finish_failure();
        }
    }

    auto connect_failure() const -> boost::system::error_code
    {
        if (ipv6_connect_error_ && ipv4_connect_error_)
        {
            // Prefer the IPv6 error unless it only reflects local IPv6
            // trouble and IPv4 produced a more informative error.
            return is_local_unreachable(ipv6_connect_error_) && not is_local_unreachable(ipv4_connect_error_)
                ? ipv4_connect_error_
                : ipv6_connect_error_;
        }
        return ipv6_connect_error_ ? ipv6_connect_error_ : ipv4_connect_error_;
    }

    auto finish_failure() -> void
    {
        if (auto const error = connect_failure())
        {
            finish(error);
        }
        else if (ipv6_resolve_error_ && not is_name_not_found(ipv6_resolve_error_))
        {
            finish(ipv6_resolve_error_);
        }
        else if (ipv4_resolve_error_ && not is_name_not_found(ipv4_resolve_error_))
        {
            finish(ipv4_resolve_error_);
        }
        else if (ipv6_resolve_error_)
        {
            finish(ipv6_resolve_error_);
        }
        else if (ipv4_resolve_error_)
        {
            finish(ipv4_resolve_error_);
        }
        else
        {
            finish(asio::error::host_not_found);
        }
    }

    auto cancel() -> void
    {
        finish(asio::error::operation_aborted);
    }

    auto finish(
        boost::system::error_code const error,
        std::shared_ptr<tcp::socket> const& winner = {},
        tcp::endpoint const& endpoint = {}
    ) -> void
    {
        if (done_)
        {
            return;
        }
        done_ = true;

        ipv4_resolver_.cancel();
        ipv6_resolver_.cancel();
        ++timer_generation_;
        timer_pending_ = false;
        timer_.cancel();
        ++resolution_timer_generation_;
        resolution_timer_pending_ = false;
        resolution_timer_.cancel();
        boost::system::error_code ignored;
        for (auto const& attempt : attempts_)
        {
            if (attempt != winner)
            {
                attempt->close(ignored);
            }
        }

        close_cancellation_.clear();

        // Everything that touches caller-owned state (their socket, their
        // cancellation slot) happens inside the posted completion, on the
        // handler's executor, immediately before the handler resumes.
        auto executor = asio::get_associated_executor(handler_, strand_);
        asio::post(
            executor,
            [handler = std::move(handler_),
             slot = associated_cancellation_,
             socket = &socket_,
             winner,
             error,
             endpoint]() mutable {
                slot.clear();
                if (winner)
                {
                    *socket = std::move(*winner);
                }
                std::move(handler)(error, endpoint);
            }
        );
    }
};

} // namespace

auto happy_eyeballs::async_connect(
    boost::asio::ip::tcp::socket& socket,
    std::string host,
    std::string service,
    CancellationSource& close_cancellation
) -> boost::asio::awaitable<boost::asio::ip::tcp::endpoint>
{
    using Signature = void(boost::system::error_code, boost::asio::ip::tcp::endpoint);
    auto token = boost::asio::use_awaitable;

    if (socket.is_open())
    {
        throw boost::system::system_error{boost::asio::error::already_open};
    }

    // Checked here, on the coroutine's own executor with no suspension point
    // before the initiation below, so an already-cancelled coroutine never
    // starts any work.
    auto const cancellation_state = co_await boost::asio::this_coro::cancellation_state;
    if (cancellation_state.cancelled() != boost::asio::cancellation_type::none)
    {
        throw boost::system::system_error{boost::asio::error::operation_aborted};
    }

    co_return co_await boost::asio::async_initiate<
        decltype(token),
        Signature
    >(
        // host and service are captured by reference: the initiation runs
        // synchronously inside co_await, while this coroutine frame is alive.
        // (Moving them via init-captures miscompiles on GCC 11.)
        [&socket, &close_cancellation, &host, &service](auto handler) mutable {
            using Handler = decltype(handler);
            auto const associated_cancellation = boost::asio::get_associated_cancellation_slot(handler);
            auto operation = std::make_shared<ConnectOperation<Handler>>(
                socket,
                std::move(handler),
                associated_cancellation,
                close_cancellation,
                host,
                service
            );
            operation->start();
        },
        token
    );
}
