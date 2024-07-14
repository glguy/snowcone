#pragma once

template <typename>
struct Invoke_;
template <typename F, typename R, typename... Ts>
struct Invoke_<R (F::*)(Ts...) const>
{
    static R invoke(Ts... args, void* u)
    {
        return (*reinterpret_cast<F const*>(u))(args...);
    }
    static void* prep(F const& fp)
    {
        return const_cast<void*>(static_cast<void const*>(&fp));
    }
};

template <typename F>
using Invoke = Invoke_<decltype(&F::operator())>;
