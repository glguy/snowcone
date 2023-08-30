return function(target)
    local prefix = ""
    while irc_state.statusmsg:find(target:sub(1,1), 1, true) do
        prefix = prefix .. target:sub(1,1)
        target = target:sub(2)
    end
    if prefix == '' then
        prefix = nil
    end
    return prefix, target
end
