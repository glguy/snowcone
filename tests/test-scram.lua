-- RFC 5802 SCRAM-SHA-1 example exchange against ircc/sasl/scram.lua, using
-- snowcone's real crypto.
--
-- Run with:  snowcone script tests/test-scram.lua

local here = (arg and arg[0] or ''):match('^(.*)/[^/]*$') or '.'
package.path = here .. '/../ircc/?.lua;' .. here .. '/../ircc/?/init.lua;' .. package.path

-- string:startswith comes from Penlight's stringx in the real client
function string.startswith(s, prefix) return s:sub(1, #prefix) == prefix end

local impl = require 'sasl.scram'
local thread = impl('sha1', nil, 'user', 'pencil', 'fyko+d2lbbFgONRv9qkxdawL')
local success, message
success, message = coroutine.resume(thread, '')
assert(success and message == 'n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL')
success, message = coroutine.resume(thread, 'r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096')
assert(success and message == 'c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=')
success, message = coroutine.resume(thread, 'v=rmF9pqV8S7suAoZWja4dJRkFsKQ=')
assert(success and message == '')
