#pragma once

#include <uv.h>

#include <iterator>
#include <ranges>

class AddrInfo {
    addrinfo* const ai;

public:
    AddrInfo() : ai() {}
    AddrInfo(addrinfo* ai) : ai(ai) {}
    ~AddrInfo() { uv_freeaddrinfo(ai); }

    template <typename T>
    class iterator_impl {
        addrinfo* ai;
    
    public:
        using iterator_category = std::input_iterator_tag;
        using difference_type = std::ptrdiff_t;
        using value_type = T;
        using reference = value_type&;
        using pointer = value_type*;

        iterator_impl() : ai() {}
        explicit iterator_impl(addrinfo* ai) : ai(ai) {}

        reference operator*() const { return *ai; }
        pointer operator->() const { return ai; }
        bool operator==(iterator_impl rhs) const { return ai == rhs.ai; }
        bool operator!=(iterator_impl rhs) const { return ai != rhs.ai; }
        iterator_impl& operator++() { ai = ai->ai_next; return *this; }
        iterator_impl operator++(int) { auto tmp = *this; ai = ai->ai_next; return tmp; }
    };

    using iterator = iterator_impl<addrinfo>;
    using const_iterator = iterator_impl<const addrinfo>;

    using value_type = addrinfo;
    using reference = value_type&;
    using const_reference = value_type const&;
    using difference_type = iterator::difference_type;
    using size_type = size_t;

    auto begin() { return iterator{ai}; }
    auto end() { return iterator{}; }

    auto begin() const { return const_iterator{ai}; }
    auto end() const { return const_iterator{}; }

    auto cbegin() const { return const_iterator{ai}; }
    auto cend() const { return const_iterator{}; }
};

static_assert(std::ranges::input_range<AddrInfo>);
