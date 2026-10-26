-- Entry point for `snowcone hub`, re-run by SIGUSR1 and /reload.
--
-- The C++ side reports a load error here by leaving curses mode, so this
-- file stays small and the real work happens in runtime/loader.lua, whose
-- errors are caught and logged without disturbing the running generation.
--
-- Tests call this chunk with an options table (see runtime/loader.lua).

local opts <const> = ... or {}
local init <const> = opts.init or arg[0]
local root <const> = opts.root or init:match '^(.*)/[^/]*$' or '.'

local loader <const> = assert(loadfile(root .. '/runtime/loader.lua'))()
return loader.reload(root, init, 'hub.app', opts)
