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
    std::vector<char> buffer_;

    // [std::begin(buffer), end_) contains buffered data
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
        return boost::asio::buffer(&*end_, std::distance(end_, buffer_.end()));
    }

    /**
     * @brief Commit new buffer bytes and dispatch line callback
     *
     * The first n bytes of the buffer will be considered to be
     * populated. The line callback function will be called once
     * per completed line. Those lines are removed from the buffer
     * and the is ready for additional calls to prepare and
     * commit.
     *
     * @param n Bytes written to the last call of prepare
     * @param line_cb Callback function to run on each completed line
     */
    auto commit(std::size_t const n) -> void
    {
        std::advance(end_, n);
    }

    /**
     * @brief Return the next null-terminated line in the buffer
     *
     * This function should be repeatedly called until it returns
     * nullptr. After that shift can be used to reclaim the
     * previously used buffer.
     *
     * @return null-terminated line or nullptr if no line is ready
     */
    auto next_line() -> char*;

    /**
     * @brief Reclaim used buffer space invalidating all previous
     * next_line() results;
     * 
     */
    auto shift() -> void;
};
