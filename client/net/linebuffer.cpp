#include "linebuffer.hpp"

auto LineBuffer::next_line() -> char*
{
    auto const nl = std::find(search_, end_, '\n');
    if (nl == end_) // no newline found, line incomplete
    {
        search_ = end_;
        return nullptr;
    }

    // Null-terminate the line. Support both \n and \r\n
    *(start_ < nl && *std::prev(nl) == '\r' ? std::prev(nl) : nl) = '\0';

    auto const result = start_;
    start_ = search_ = std::next(nl);

    return &*result;
}

auto LineBuffer::shift() -> void
{
    auto const first = std::begin(buffer_);
    auto const gap = std::distance(start_, first);
    if (gap != 0) // relocate incomplete line to front of buffer
    {
        end_ = std::move(start_, end_, first);
        start_ = first;
        std::advance(search_, gap);
    }
}
