-- Validation of configuration tables against a schema. Errors are
-- raised; unexpected fields are
-- collected as warnings instead of logged, so this stays pure.

local tablex <const> = require 'pl.tablex'

local M = {}

local function fail(fmt, ...)
    error(string.format(fmt, ...), 0)
end

---@param schema table
---@param value any
---@param path string[]|nil field names leading to value
---@param warnings string[]|nil receives a message per unexpected field
function M.check(schema, value, path, warnings)
    path = path or {}
    warnings = warnings or {}

    if value == nil then
        if schema.required then
            fail('Missing field: %s', table.concat(path, '.'))
        else
            return
        end
    end

    if schema.oneOf then
        local msg = "No alternatives available: " .. table.concat(path, '.')
        for i, subschema in ipairs(schema.oneOf) do
            local save_path = tablex.copy(path)
            -- only the alternative that matches may report unexpected fields
            local sub_warnings = {}
            local success, submsg = pcall(M.check, subschema, value, path, sub_warnings)
            path = save_path
            if success then
                table.move(sub_warnings, 1, #sub_warnings, #warnings + 1, warnings)
                return
            end
            if i > 1 then
                msg = msg .. "; " .. submsg
            else
                msg = "All alternatives failed in " .. table.concat(path, '.') .. ": " .. submsg
            end
        end
        error(msg, 0)

    elseif schema.type then
        if schema.type ~= type(value) then
            fail('Type mismatch in %s expected: %s got: %s',
                table.concat(path, '.'), schema.type, type(value))
        end

        if schema.type == 'table' then
            local validated = {}
            if schema.elements then
                for i, elt in ipairs(value) do
                    validated[i] = true
                    table.insert(path, i)
                    M.check(schema.elements, elt, path, warnings)
                    table.remove(path)
                end
            elseif schema.fields then
                for k, v in pairs(schema.fields) do
                    validated[k] = true
                    table.insert(path, k)
                    M.check(v, value[k], path, warnings)
                    table.remove(path)
                end
            elseif schema.assocs then
                for k, v in pairs(value) do
                    table.insert(path, k)
                    M.check(v, value[k], path, warnings)
                    table.remove(path)
                end
                -- all fields are implicitly validated, skip unexpected check
                return
            else
                -- unregulated tables don't need unexpected field checks
                return
            end

            for k, _ in pairs(value) do
                if not validated[k] then
                    table.insert(path, k)
                    table.insert(warnings, 'Unexpected field ' .. table.concat(path, '.'))
                    table.remove(path)
                end
            end

        elseif schema.type == 'number' then
            local where = table.concat(path, '.')
            if schema.integer and math.tointeger(value) == nil then
                fail('Expected an integer in %s got: %s', where, tostring(value))
            end
            if schema.minimum and value < schema.minimum then
                fail('Value in %s is below the minimum %s: %s',
                    where, tostring(schema.minimum), tostring(value))
            end
            if schema.maximum and value > schema.maximum then
                fail('Value in %s is above the maximum %s: %s',
                    where, tostring(schema.maximum), tostring(value))
            end

        elseif schema.type == 'string' then
            if schema.pattern and not value:find(schema.pattern) then
                -- `expected` says in words what the pattern requires
                if schema.expected then
                    fail('Pattern failure in %s: expected %s', table.concat(path, '.'), schema.expected)
                end
                fail('Pattern failure in %s', table.concat(path, '.'))
            end
        end
    end
end

return M
