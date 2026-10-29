-- Error handler for xpcall: a traceback for errors from code (those with
-- a source position), just the message for errors raised for the user
-- with level 0, such as configuration and usage errors, and bad input
-- from a server.
--
-- Given a coroutine, the traceback is of that coroutine, for an error
-- that coroutine.resume returned.

---@param err any
---@param co thread|nil
---@return any
return function(err, co)
    if type(err) == 'string' and not err:match '^[^:\n]+:%d+:' then
        return err
    end
    if co then
        return debug.traceback(co, err)
    end
    return debug.traceback(err, 2)
end
