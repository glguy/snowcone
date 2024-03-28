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

#include <concepts>
#include <string>

/**
 * @brief Fixed-size buffer with line-oriented dispatch
 *
 */
class LineBuffer
{
    std::string buffer;

    // [0, used_) contains buffered data
    // [used_, size) is available buffer space
    std::size_t used_;

public:
    /**
     * @brief Construct a new Line Buffer object
     *
     * @param n Buffer size
     */
    LineBuffer(std::size_t n) : buffer(n, '\0'), used_{0} {}

    /**
     * @brief Get the available buffer space
     *
     * @return boost::asio::mutable_buffer
     */
    auto get_buffer() -> boost::asio::mutable_buffer
    {
        return boost::asio::buffer(&buffer[used_], buffer.size() - used_);
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
        auto const start = used_;
        used_ += n;

        // new data is now located in [start, used_)

        // cursor marks the beginning of the current line
        auto cursor = 0;

        for (auto nl = buffer.find('\n', start);
             nl != buffer.npos;
             nl = buffer.find('\n', cursor))
        {
            // Null-terminate the line. Support both \n and \r\n
            if (cursor < nl && buffer[nl - 1] == '\r')
            {
                buffer[nl - 1] = '\0';
            }
            else
            {
                buffer[nl] = '\0';
            }

            line_cb(&buffer[cursor]);

            cursor = nl + 1;
        }

        // If any lines were processed, move all processed lines to
        // the front of the buffer
        if (cursor != 0)
        {
            buffer.erase(0, cursor);
            used_ -= cursor;
        }
    }
};
