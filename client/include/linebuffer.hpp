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

    // [buffer.begin(), end_) contains buffered data
    // [end_, buffer.end()) is available buffer space
    std::vector<char>::iterator end_;

public:
    /**
     * @brief Construct a new Line Buffer object
     * 
     * @param n Buffer size
     */
    LineBuffer(std::size_t n) : buffer(n), end_{buffer.begin()} {}

    /**
     * @brief Get the available buffer space
     * 
     * @return boost::asio::mutable_buffers_1 
     */
    auto get_buffer() -> boost::asio::mutable_buffers_1
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
        auto const start = end_;
        std::advance(end_, n);

        // new data is now located in [start, end_)

        // cursor marks the beginning of the current line
        auto cursor = buffer.begin();

        for (auto nl = std::find(start, end_, '\n');
             nl != end_;
             nl = std::find(cursor, end_, '\n'))
        {
            // Null-terminate the line. Support both \n and \r\n
            if (cursor < nl && *std::prev(nl) == '\r')
            {
                *std::prev(nl) = '\0';
            }
            else
            {
                *nl = '\0';
            }

            line_cb(&*cursor);

            cursor = std::next(nl);
        }

        // If any lines were processed, move all processed lines to
        // the front of the buffer
        if (cursor != buffer.begin())
        {
            end_ = std::move(cursor, end_, buffer.begin());
        }
    }
};
