/**
 * @file uvaddrinfo.hpp
 * @author Eric Mertens (emertens@gmail.com)
 * @brief stdlib Container adapter for libuv allocated addrinfo
 *
 */

#pragma once

#include <uv.h>

#include <iterator>
#include <memory>

/**
 * @brief Container of addrinfo
 *
 */
class AddrInfo {
    struct Deleter { void operator()(addrinfo* ai) const { uv_freeaddrinfo(ai); } };
    std::unique_ptr<addrinfo, Deleter> ai;

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
        iterator_impl& operator++() { next(); return *this; }
        iterator_impl operator++(int) { auto tmp = *this; next(); return tmp; }

        friend bool operator==(iterator_impl lhs, iterator_impl rhs) {
            return lhs.ai == rhs.ai;
        }
    };

public:
    /**
     * @brief Construct a new empty list of addrinfo
     */
    AddrInfo() : ai() {}

    /**
     * @brief Construct a new nonempty addrinfo
     *
     * @param ai Head of list allocated by libuv
     */
    AddrInfo(addrinfo* ai) : ai(ai) {}

    using iterator = iterator_impl<addrinfo>;
    using const_iterator = iterator_impl<const addrinfo>;

    using value_type = addrinfo;
    using reference = value_type&;
    using const_reference = value_type const&;
    using size_type = size_t;

    iterator begin() { return iterator{ai.get()}; }
    iterator end() { return iterator{}; }

    const_iterator cbegin() const { return const_iterator{ai.get()}; }
    const_iterator cend() const { return const_iterator{}; }

    const_iterator begin() const { return cbegin(); }
    const_iterator end() const { return cend(); }
};
