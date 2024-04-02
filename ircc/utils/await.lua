return function(f, ...)
    local co, is_main = coroutine.running()
    assert(not is_main, "can't wrap main")
    local args = {...}
    table.insert(args, function(...)
        coroutine.resume(co, ...)
    end)
    f(table.unpack(args))
    return coroutine.yield()
end
