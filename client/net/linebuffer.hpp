#pragma once
/**
 * @file linebuffer.hpp
 * @author Eric Mertens <emertens@gmail.com>
 * @brief A line buffering class
 * @version 0.1
 * @date 2023-08-22
 *
 * @copyright Copyright (c) 2023
 *
 */

#include <boost/asio/buffer.hpp>

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <iterator>
#include <memory>
#include <vector>

/**
 * @brief Fixed-size buffer with line-oriented dispatch
 *
 */
class LineBuffer
{
    std::vector<char> buffer_;

    // [std::begin(buffer), start_) holds lines already returned by next_line
    // [start_, end_) is buffered data not yet returned as a line
    // [search_, end_) is the part of that not yet searched for a newline
    // [end_, std::end(buffer)) is available buffer space
    decltype(buffer_)::iterator start_;
    decltype(buffer_)::iterator search_;
    decltype(buffer_)::iterator end_;

public:
    /**
     * @brief Construct a new Line Buffer object
     *
     * @param n Buffer size
     */
    LineBuffer(std::size_t n)
        : buffer_(n)
        , start_{buffer_.begin()}
        , search_{buffer_.begin()}
        , end_{buffer_.begin()}
    {
    }

    // can't copy the iterator member safely
    LineBuffer(LineBuffer const&) = delete;
    LineBuffer(LineBuffer&&) = delete;
    auto operator=(LineBuffer const&) -> LineBuffer& = delete;
    auto operator=(LineBuffer&&) -> LineBuffer& = delete;

    /**
     * @brief Get the available buffer space
     *
     * @return boost::asio::mutable_buffer
     */
    auto prepare() -> boost::asio::mutable_buffer
    {
        return boost::asio::buffer(std::to_address(end_), std::distance(end_, buffer_.end()));
    }

    /**
     * @brief Commit bytes written into the space returned by prepare
     *
     * The first n bytes of that space become buffered data, available
     * to next_line.
     *
     * @param n Bytes written; at most the size returned by the last prepare
     */
    auto commit(std::size_t const n) -> void
    {
        assert(n <= static_cast<std::size_t>(std::distance(end_, buffer_.end())));
        std::advance(end_, n);
    }

    /**
     * @brief Return the next null-terminated line in the buffer
     *
     * The line ending, "\n" or "\r\n", is replaced by the terminator.
     * Call this repeatedly until it returns nullptr, then call shift
     * before the next prepare.
     *
     * @return null-terminated line or nullptr if no line is ready
     */
    auto next_line() -> char*;

    /**
     * @brief Reclaim the space of lines already returned
     *
     * Moves any incomplete line to the front of the buffer. This
     * invalidates every pointer returned by next_line. Call it once
     * next_line has returned nullptr: shifting earlier is safe but
     * moves complete lines that could have been returned first.
     */
    auto shift() -> void;
};
