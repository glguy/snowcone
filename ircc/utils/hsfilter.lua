local function send_db(check, db)
    local chunksize = 300
    local pattern = "SETFILTER * %s %s%s\r\n"

    conn:send(pattern:format(check, '', 'NEW'))

    for i = 1, db:len(), chunksize do
        local chunk = snowcone.to_base64(db:sub(i, i+chunksize-1))
        conn:send(pattern:format(check, '+', chunk))
    end

    conn:send(pattern:format(check, '', 'APPLY'))
end

return function(exprs, flags, ids, platform)
    local check = math.random(0)
    local db = hsfilter.serialize_regexp_db(exprs, flags, ids, platform)
    send_db(check, db)
end
