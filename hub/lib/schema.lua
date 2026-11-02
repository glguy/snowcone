-- Validation of configuration tables against a schema. Any mismatch,
-- including a field the schema doesn't name, raises an error.

local tablex <const> = require 'pl.tablex'

local M = {}

local function fail(fmt, ...)
    error(string.format(fmt, ...), 0)
end

---@param schema table
---@param value any
---@param path string[]|nil field names leading to value
function M.check(schema, value, path)
    path = path or {}

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
            -- a copy: a failed alternative leaves its own fields on it
            local success, submsg = pcall(M.check, subschema, value, tablex.copy(path))
            if success then
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
                    M.check(schema.elements, elt, path)
                    table.remove(path)
                end
            elseif schema.fields then
                for k, v in pairs(schema.fields) do
                    validated[k] = true
                    table.insert(path, k)
                    M.check(v, value[k], path)
                    table.remove(path)
                end
            elseif schema.assocs then
                for k, v in pairs(value) do
                    table.insert(path, k)
                    M.check(schema.assocs, v, path)
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
                    fail('Unexpected field %s', table.concat(path, '.'))
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
            if schema.values and not schema.values[value] then
                local names = {}
                for name in pairs(schema.values) do table.insert(names, name) end
                table.sort(names)
                fail('%s must be one of %s, not %s', table.concat(path, '.'), table.concat(names, ', '), value)
            end
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
