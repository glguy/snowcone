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
#include <concepts>
#include <vector>

/**
 * @brief Fixed-size buffer with line-oriented dispatch
 *
 */
class LineBuffer
{
    std::vector<char> buffer;

    // [std::begin(buffer), end_) contains buffered data
    // [end_, std::end(buffer)) is available buffer space
    std::vector<char>::iterator end_;

public:
    /**
     * @brief Construct a new Line Buffer object
     *
     * @param n Buffer size
     */
    LineBuffer(std::size_t n) : buffer(n), end_{buffer.begin()} {}

    // can't copy the iterator member safely
    LineBuffer(LineBuffer const&) = delete;
    auto operator=(LineBuffer const&) -> LineBuffer& = delete;
    LineBuffer(LineBuffer &&) = delete;
    auto operator=(LineBuffer &&) -> LineBuffer& = delete;

    /**
     * @brief Get the available buffer space
     *
     * @return boost::asio::mutable_buffer
     */
    auto get_buffer() -> boost::asio::mutable_buffer
    {
        return boost::asio::buffer(&*end_, std::distance(end_, buffer.end()));
    }

    /**
     * @brief Commit new buffer bytes and dispatch line callback
     *
     * The first n bytes of the buffer will be considered to be
     * populated. The line callback function will be called once
     * per completed line. Those lines are removed from the buffer
     * and the is ready for additional calls to get_buffer and
     * add_bytes.
     *
     * @param n Bytes written to the last call of get_buffer
     * @param line_cb Callback function to run on each completed line
     */
    auto add_bytes(std::size_t n, std::invocable<char *> auto line_cb) -> void
    {
        // Remember where to resume looking for \n
        auto const start = end_;

        // Record added bytes as part of the populated buffer
        std::advance(end_, n);

        // cursor marks the beginning of the current line
        auto cursor = std::begin(buffer);

        for (auto nl = std::find(start, end_, '\n');
             nl != end_;
             nl = std::find(cursor, end_, '\n'))
        {
            // Null-terminate the line. Support both \n and \r\n
            *(cursor < nl && *std::prev(nl) == '\r' ? std::prev(nl) : nl) = '\0';

            line_cb(&*cursor);

            cursor = std::next(nl);
        }

        // If any lines were processed remove any remaining partial line
        // to the front of the buffer.
        if (cursor != std::begin(buffer))
        {
            end_ = std::move(cursor, end_, std::begin(buffer));
        }
    }
};
