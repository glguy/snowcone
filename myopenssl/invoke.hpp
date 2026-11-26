#pragma once

// Adapts a capturing lambda to an OpenSSL-style C callback whose last
// parameter is a void* user-data pointer.

/// Specialized below on a const call operator's member-function type.
template <typename>
struct Invoke_;
template <typename F, typename R, typename... Ts>
struct Invoke_<R (F::*)(Ts...) const>
{
    /// C callback: calls the lambda that prep made u from with args.
    static R invoke(Ts... args, void* u)
    {
        return (*reinterpret_cast<F const*>(u))(args...);
    }
    /// User-data pointer for invoke. Borrows fp, which must outlive every
    /// call OpenSSL makes through it.
    static void* prep(F const& fp)
    {
        return const_cast<void*>(static_cast<void const*>(&fp));
    }
};

/// Invoke<decltype(lambda)>::invoke and ::prep(lambda) form a callback and
/// user-data pair. The lambda's parameters must match the C callback's,
/// minus the trailing void*.
template <typename F>
using Invoke = Invoke_<decltype(&F::operator())>;
