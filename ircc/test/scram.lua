local scram = require_ 'sasl.scram'

local c1 = 'n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL'
local s1 = 'r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096'
local c2 = 'c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts='
local s2 = 'v=rmF9pqV8S7suAoZWja4dJRkFsKQ='
local nonce = 'fyko+d2lbbFgONRv9qkxdawL'

local function step(expect, co, input)
    local _, c = assert(coroutine.resume(co, input))
    assert(expect == c)
end

local co = scram('sha1', nil, 'user', 'pencil', nonce)
step(c1, co)
step(c2, co, s1)
step('', co, s2)
print('ok')
