local await = require 'utils.await'

return function(entry)

    local t = type(entry)

    if t == 'nil' then
        return nil
    end

    if t == 'string' then
        return entry
    end

    if t == 'table' then
        local exit_code, stdout, stderr = await(snowcone.execute, entry.command, entry.arguments)
        if exit_code == 0 then
            return (stdout:match '^[^\n]*')
        else
            error('Password command failed: ' .. stderr)
        end
    end

    error('Bad password entry: ' .. tostring(entry))
end