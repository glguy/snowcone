local function send_db(check, db)
    local send = require'utils.send'
    local chunksize = 300

    send('SETFILTER', '*', check, 'NEW')

    for i = 1, db:len(), chunksize do
        local chunk = mybase64.to_base64(db:sub(i, i+chunksize-1))
        send('SETFILTER', '*', check, '+' .. chunk)
    end

    send('SETFILTER', '*', check, 'APPLY')
end

return function(exprs, flags, ids, platform)
    local check = math.random(0)
    local db = hsfilter.serialize_regexp_db(exprs, flags, ids, platform)
    send_db(check, db)
end
