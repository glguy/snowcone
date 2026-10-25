# mystringprep

A small Lua binding to libidn's implementation of
[stringprep](https://datatracker.ietf.org/doc/html/rfc3454).

```lua
local stringprep = require 'mystringprep'.stringprep
local prepared = stringprep(str, profile)
```

`profile` is any libidn profile name, such as `'SASLprep'`
([RFC 4013](https://datatracker.ietf.org/doc/html/rfc4013)) or `'trace'`.
Strings are prepared as queries: unassigned code points are allowed.

It raises "stringprep failed: ..." when the input is rejected, for example
for a prohibited character or invalid UTF-8, or when the profile is unknown.
A string containing a NUL byte is rejected, because libidn takes C strings.
