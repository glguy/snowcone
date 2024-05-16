#pragma once

template <typename>
struct Invoke_;
template <typename F, typename R, typename... Ts>
struct Invoke_<R (F::*)(Ts...) const>
{
    static R invoke(Ts... args, void* u)
    {
        return (*reinterpret_cast<F*>(u))(args...);
    }
};

template <typename F>
using Invoke = Invoke_<decltype(&F::operator())>;
