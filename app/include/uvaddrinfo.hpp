#pragma once

#include <uv.h>

#include <iterator>
#include <memory>
#include <ranges>

class AddrInfo {
    struct Deleter { void operator()(addrinfo* ai) const { uv_freeaddrinfo(ai); } };
    std::unique_ptr<addrinfo, Deleter> ai;

public:
    AddrInfo() : ai() {}
    AddrInfo(addrinfo* ai) : ai(ai) {}

    template <typename T>
    class iterator_impl {
        T* ai;

        inline void next() { ai = ai->ai_next; }
    
    public:
        using iterator_category = std::input_iterator_tag;
        using difference_type = std::ptrdiff_t;
        using value_type = T;
        using reference = value_type&;
        using pointer = value_type*;

        explicit iterator_impl() : ai() {}
        explicit iterator_impl(addrinfo* ai) : ai(ai) {}

        reference operator*() const { return *ai; }
        pointer operator->() const { return ai; }
        bool operator==(iterator_impl rhs) const { return ai == rhs.ai; }
        iterator_impl& operator++() { next(); return *this; }
        iterator_impl operator++(int) { auto tmp = *this; next(); return tmp; }
    };

    using iterator = iterator_impl<addrinfo>;
    using const_iterator = iterator_impl<const addrinfo>;

    using value_type = addrinfo;
    using reference = value_type&;
    using const_reference = value_type const&;
    using size_type = size_t;

    auto begin() { return iterator{ai.get()}; }
    auto end() { return iterator{}; }

    auto cbegin() const { return const_iterator{ai.get()}; }
    auto cend() const { return const_iterator{}; }

    auto begin() const { return const_iterator{ai.get()}; }
    auto end() const { return const_iterator{}; }
};

static_assert(std::ranges::input_range<AddrInfo>);
