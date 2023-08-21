#pragma once

#include <vector>
#include <boost/asio.hpp>

class LineBuffer {
    std::vector<char> buffer;
    std::vector<char>::iterator end_;

public:
    LineBuffer(std::size_t n) : buffer(n), end_{buffer.begin()} {}

    auto get_buffer() {
        return boost::asio::buffer(&*end_, buffer.end() - end_);
    }

    auto add_bytes(std::size_t n, auto f) -> void {
        auto const start = end_;
        end_ += n;
        
        auto cursor = buffer.begin();

        for (auto nl = std::find(start, end_, '\n');
             nl != end_;
             nl = std::find(cursor, end_, '\n'))
        {
            // Null-terminate the line terminator
            if (cursor < nl && *(nl-1) == '\r')
            {
                *(nl-1) = '\0';
            }
            else
            {
                *nl = '\0';
            }

            f(&*cursor);
            
            cursor = nl + 1;
        }

        if (cursor != buffer.begin()) {
            auto used = cursor - buffer.begin();
            std::move(cursor, end_, buffer.begin());
            end_ -= used;
        }
    }
};
