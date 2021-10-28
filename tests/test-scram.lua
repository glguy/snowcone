local impl = require 'sasl.scram'
local thread = impl('sha1', nil, 'user', 'pencil', 'fyko+d2lbbFgONRv9qkxdawL')
local success, message
success, message = coroutine.resume(thread, '')
assert(success and message == 'n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL')
success, message = coroutine.resume(thread, 'r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096')
assert(success and message == 'c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=')
success, message = coroutine.resume(thread, 'v=rmF9pqV8S7suAoZWja4dJRkFsKQ=')
assert(success and message == '')
