#include <socks5.hpp>

#include <gtest/gtest.h>
#include <gmock/gmock.h>

#include <cstddef>
#include <cstring>
#include <deque>
#include <memory>
#include <span>
#include <stdexcept>
#include <vector>

namespace
{
    using namespace std::string_literals;

    auto buffer_span(auto const &buffers)
    {
        return std::span{
            boost::asio::buffer_sequence_begin(buffers),
            boost::asio::buffer_sequence_end(buffers)};
    }

    /// @brief A step in the mock stream
    class Step
    {
    public:
        virtual ~Step() = default;

        /// The client wants to read from the stream
        /// @returns true if step is complete
        /// @throws std::runtime_error if write doesn't match expectation
        virtual auto on_read(void *data, std::size_t size, boost::system::error_code &ec, std::size_t &len) -> bool
        {
            throw std::runtime_error{"unexpected read"};
        }

        /// The client wants to write to the stream
        /// @returns true if step is complete
        /// @throws std::runtime_error if write doesn't match expectation
        virtual auto on_write(void const *data, std::size_t size, boost::system::error_code &ec, std::size_t &len) -> bool
        {
            throw std::runtime_error{"unexpected write"};
        }
    };

    /// The mock expects a read which will be serviced with the content bytes.
    class ReadStep : public Step
    {
        std::string content_;

    public:
        ReadStep(std::string content) : content_{std::move(content)} {}
        auto on_read(void *data, std::size_t size, boost::system::error_code &ec, std::size_t &len) -> bool override
        {
            auto const amount = std::min(size, std::size(content_));
            std::memcpy(data, std::data(content_), amount);
            ec = {};
            len = amount;
            content_.erase(0, amount);
            return content_.empty();
        }
    };

    /// The mock expects a read to which it will report EOF
    class ReadEofStep : public Step
    {
    public:
        auto on_read(void *data, std::size_t size, boost::system::error_code &ec, std::size_t &len) -> bool override
        {
            ec = boost::asio::error::eof;
            len = 0;
            return true;
        }
    };

    /// The mock expects a write that must match the content bytes.
    class WriteStep : public Step
    {
        std::string content_;

    public:
        WriteStep(std::string content) : content_{std::move(content)} {}
        auto on_write(void const *data, std::size_t size, boost::system::error_code &ec, std::size_t &len) -> bool override
        {
            auto const amount = std::min(size, std::size(content_));
            if (std::memcmp(data, std::data(content_), amount))
            {
                throw std::runtime_error{"mismatched write"};
            }
            len = amount;
            content_.erase(0, amount);
            return content_.empty();
        }
    };

    using boost::asio::async_result;
    using boost::asio::execution_context;
    using boost::asio::io_context;

    class MockStream
    {

    public:
        using executor_type = io_context::executor_type;

        MockStream(executor_type executor)
            : executor_(executor) {}

        auto get_executor() const -> executor_type const & { return executor_; }

        // Simulate async read operation
        template <typename MutableBufferSequence, typename CompletionToken>
        auto async_read_some(const MutableBufferSequence &buffers, CompletionToken &&token)
        {
            std::vector<boost::asio::mutable_buffer> buffers_copy;
            for (auto&& buffer : buffers) {
                buffers_copy.push_back(boost::asio::buffer(buffer.data(), buffer.size()));
            }
            return boost::asio::async_initiate<CompletionToken, void(boost::system::error_code, std::size_t)>(
                [](auto handler, std::vector<boost::asio::mutable_buffer> buffers, std::deque<std::unique_ptr<Step>> &steps)
                {
                    if (steps.empty())
                        throw std::runtime_error{"no steps"};
                    auto &step = *steps.front();

                    boost::system::error_code ec{};
                    std::size_t transfer = 0;
                    for (auto &&buffer : buffer_span(buffers))
                    {
                        std::size_t len;
                        bool const done = step.on_read(std::data(buffer), std::size(buffer), ec, len);
                        transfer += len;
                        if (done)
                        {
                            steps.pop_front();
                            break;
                        }
                        if (ec)
                        {
                            break;
                        }
                    }
                    handler(ec, transfer);
                },
                token, std::move(buffers_copy), steps_);
        }

        // Simulate async write operation
        template <typename ConstBufferSequence, typename CompletionToken>
        auto async_write_some(const ConstBufferSequence &buffers, CompletionToken &&token)
        {
            std::vector<boost::asio::const_buffer> buffers_copy;
            for (auto&& buffer : buffers) {
                buffers_copy.push_back(boost::asio::buffer(buffer.data(), buffer.size()));
            }
            return boost::asio::async_initiate<CompletionToken, void(boost::system::error_code, std::size_t)>(
                [](auto handler, std::vector<boost::asio::const_buffer> buffers, std::deque<std::unique_ptr<Step>> &steps)
                {
                    if (steps.empty())
                        throw std::runtime_error{"no steps"};
                    auto &step = *steps.front();

                    boost::system::error_code ec{};
                    std::size_t transfer = 0;
                    for (auto &&buffer : buffer_span(buffers))
                    {
                        std::size_t len;
                        bool const done = step.on_write(std::data(buffer), std::size(buffer), ec, len);
                        transfer += len;
                        if (done)
                        {
                            steps.pop_front();
                            break;
                        }
                        if (ec)
                        {
                            break;
                        }
                    }
                    handler(ec, transfer);
                },
                token, std::move(buffers_copy), steps_);
        }

        auto read_step(std::string str) -> void
        {
            steps_.push_back(std::make_unique<ReadStep>(std::move(str)));
        }
        auto write_step(std::string str) -> void
        {
            steps_.push_back(std::make_unique<WriteStep>(std::move(str)));
        }
        auto complete() const -> bool
        {
            return steps_.empty();
        }

    private:
        executor_type executor_;
        std::deque<std::unique_ptr<Step>> steps_;
    };

    TEST(Socks5, DomainNoAuth)
    {
        io_context cxt;
        MockStream mock{cxt.get_executor()};
        mock.write_step("\5\1\0"s);
        mock.read_step("\5\0"s);
        mock.write_step("\5\1\0\3\x08testhost\x12\x34"s);
        mock.read_step("\5\0\0\1\1\2\3\4\xaa\xbb"s);

        socks5::async_connect(mock, "testhost", 0x1234, socks5::NoCredential{},
            [](boost::system::error_code e, boost::asio::ip::tcp::endpoint endpoint)
            {
                ASSERT_FALSE(e);
                boost::asio::ip::tcp::endpoint const expected_endpoint{boost::asio::ip::make_address_v4("1.2.3.4"), 0xaabb};
                ASSERT_EQ(endpoint, expected_endpoint);
            });
        cxt.run();
        ASSERT_TRUE(mock.complete());
    }

    TEST(Socks5, Ipv4Auth)
    {
        io_context cxt;
        MockStream mock{cxt.get_executor()};
        mock.write_step("\5\1\2"s);
        mock.read_step("\5\2"s);
        mock.write_step("\1\4user\4pass"s);
        mock.read_step("\1\0"s);
        mock.write_step("\5\1\0\3\x09localhost\x12\x34"s);
        mock.read_step("\5\0\0\1\1\2\3\4\xaa\xbb"s);

        socks5::async_connect(mock, "localhost", 0x1234, socks5::UsernamePasswordCredential{"user", "pass"},
            [](boost::system::error_code e, boost::asio::ip::tcp::endpoint endpoint)
            {
                ASSERT_FALSE(e);
                boost::asio::ip::tcp::endpoint const expected_endpoint{boost::asio::ip::make_address_v4("1.2.3.4"), 0xaabb};
                ASSERT_EQ(endpoint, expected_endpoint);
            });
        cxt.run();
        ASSERT_TRUE(mock.complete());
    }

} // namespace

int main(int argc, char **argv)
{
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
