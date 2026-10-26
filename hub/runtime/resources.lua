-- Native handles.
--
-- Every handle is held here so it stays reachable, since a collected timer
-- never fires, and so shutdown can close everything. The table lives in
-- HUB.resources, outside HUB.state, because handles are not data.

local M = {}

local function items()
    local r = HUB.resources
    if r.items == nil then
        r.items = {}
        r.next_id = 0
    end
    return r.items
end

--- Hold a native handle.
---@param kind string 'timer', 'connection', 'dns', ...
---@param owner string module or plugin that is responsible for it
---@param handle any
---@param finalizer string|nil method that closes it
---@return integer id
function M.add(kind, owner, handle, finalizer)
    local t = items()
    local id = HUB.resources.next_id + 1
    HUB.resources.next_id = id
    t[id] = {kind = kind, owner = owner, handle = handle, finalizer = finalizer}
    return id
end

---@return any handle, or nil if the id is unknown
function M.get(id)
    local entry = items()[id]
    return entry and entry.handle
end

--- Forget a handle without closing it, after it finished on its own.
---@return any handle, or nil if the id is unknown
function M.remove(id)
    local t = items()
    local entry = t[id]
    t[id] = nil
    return entry and entry.handle
end

local function finalize(id, entry)
    local finalizer = entry.finalizer
    if finalizer then
        local ok, err = pcall(entry.handle[finalizer], entry.handle)
        if not ok then
            io.stderr:write(string.format('closing %s %d (%s): %s\n', entry.kind, id, entry.owner, err))
        end
    end
end

--- Close a handle and forget it. Unknown ids are ignored.
function M.close(id)
    local t = items()
    local entry = t[id]
    if entry then
        t[id] = nil
        finalize(id, entry)
    end
end

--- Close every handle that an owner holds.
function M.close_owner(owner)
    local t = items()
    for id, entry in pairs(t) do
        if entry.owner == owner then
            t[id] = nil
            finalize(id, entry)
        end
    end
end

--- Close every handle, for shutdown.
function M.close_all()
    local t = items()
    for id, entry in pairs(t) do
        t[id] = nil
        finalize(id, entry)
    end
end

--- Iterate over held handles: id, {kind, owner, handle, finalizer}
function M.each()
    return pairs(items())
end

return M
