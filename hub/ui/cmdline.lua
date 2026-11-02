-- The command line's commands (commands/run.lua) act on the current
-- network and the buffer shown for it, and /addwatch can take the
-- cliconn view's filter.

local control <const> = require 'hub.ui.control'
local run     <const> = require 'hub.commands.run'

local M = {}

---@param ctx hub.CommandContext
local function context(ctx)
    ctx.target = ctx.net and control.talk_target(ctx.net)
    ctx.filter = control.filter 'cliconn'
end

---@return hub.CommandOrigin
local function origin()
    return {net = control.current_net(), context = context}
end

--- Parse and run one command line (without the leading slash).
---@param text string
function M.execute(text)
    run.execute(text, origin())
end

--- A command can be used on the current network.
function M.available(cmd)
    return run.available(cmd, control.current_net())
end

--- Command names starting with a prefix, sorted; after name@, the
--- network ids for a net command.
---@param seed string
---@return string[]
function M.complete(seed)
    return run.complete(seed, control.current_net())
end

--- Tab's candidates for a command's argument, or nil for the default.
---@param prefix string the line before the word being completed
---@param seed string the start of that word
---@return string[]|nil
function M.complete_args(prefix, seed)
    return run.complete_args(prefix, seed, origin())
end

return M
