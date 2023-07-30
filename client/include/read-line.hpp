/**
 * @file read-line.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief Line-oriented buffer for reading from libuv streams
 *
 */

#pragma once

#include "uv.hpp"

#include <uv.h>

#include <algorithm>
#include <array>
#include <concepts>
#include <iterator>
#include <functional>
#include <type_traits>

/**
 * @brief Install line-oriented callbacks for reading from stream
 *
 * This implementation makes use of the stream's data pointer.
 *
 * @tparam N Buffer size
 * @tparam LineCb Callback type for on_line event closure
 * @tparam DoneCb Callback type for on_done event closure
 * @param stream Open stream
 * @param on_line Callback for each line of stream
 * @param on_done Callback for stream close event
 * @param on_delete Deallocation callback for stream
 */
template <
    std::size_t N = 32000,
    std::invocable<char *> LineCb,
    std::invocable<ssize_t> DoneCb>
auto readline_start(uv_stream_t *stream, LineCb &&on_line, DoneCb &&on_done, uv_close_cb on_delete) -> void
{
    class readline_data
    {
        using buffer_type = std::array<char, N>;
        buffer_type buffer;
        typename buffer_type::iterator end;

        std::remove_reference_t<LineCb> on_line;
        std::remove_reference_t<DoneCb> on_done;
        uv_close_cb on_delete;

    public:
        static auto from(uv_stream_t const *const stream) -> readline_data *
        {
            return reinterpret_cast<readline_data *>(stream->data);
        }

        static auto from(uv_handle_t const *const handle) -> readline_data *
        {
            return reinterpret_cast<readline_data *>(handle->data);
        }

        readline_data(LineCb &&on_line, DoneCb &&on_done, uv_close_cb const on_delete) noexcept
            : end{std::begin(buffer)},
              on_line{std::forward<LineCb>(on_line)},
              on_done{std::forward<DoneCb>(on_done)},
              on_delete{on_delete}
        {
        }

        auto allocate() const noexcept -> uv_buf_t
        {
            return uv_buf_init(end, std::distance(typename buffer_type::const_iterator{end}, std::end(buffer)));
        }

        auto read_cb(uv_stream_t *const stream, ssize_t const nread, uv_buf_t const *const buf) noexcept -> void
        {
            if (nread < 0)
            {
                uv_close(handle_cast(stream), on_delete);
                on_done(nread);
                stream->data = nullptr;
                delete this;
            }
            else
            {
                // remember start of this chunk; there should be no newline before it
                auto const chunk = end;

                // advance end iterator to end of current chunk
                std::advance(end, nread);
                // The newly read bytes are now in [chunk,end)

                auto nl = std::find(chunk, end, '\n');
                if (end != nl)
                {
                    auto cursor = std::begin(buffer);
                    do
                    {
                        // detect and support carriage return before newline
                        if (cursor < nl)
                        {
                            auto const cr = std::prev(nl);
                            if ('\r' == *cr)
                            {
                                *cr = '\0';
                            }
                        }

                        *nl = '\0';
                        on_line(cursor);
                        cursor = std::next(nl);
                        nl = std::find(cursor, end, '\n');
                    } while (end != nl);

                    // move remaining incomplete line to the front of the buffer
                    end = std::copy(cursor, end, std::begin(buffer));
                }
            }
        }
    };

    auto data = std::make_unique<readline_data>(std::forward<LineCb>(on_line), std::forward<DoneCb>(on_done), on_delete);
    stream->data = data.get();
    uvok(uv_read_start(
        stream,

        [](uv_handle_t *const handle, size_t const suggested_size, uv_buf_t *const buf)
        {
            *buf = readline_data::from(handle)->allocate();
        },

        [](uv_stream_t *const stream, ssize_t const nread, uv_buf_t const *const buf)
        {
            readline_data::from(stream)->read_cb(stream, nread, buf);
        }));
    data.release();
}
