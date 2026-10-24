local tablex = require 'pl.tablex'

local M = {}

function M.check(schema, value, path)
    path = path or {}

    if value == nil then
        if schema.required then
            error(string.format('Missing field: %s',
                table.concat(path, '.')
            ))
        else
            return
        end
    end

    if schema.oneOf then
        local msg = "No alternatives available: " .. table.concat(path, '.')
        for i, subschema in ipairs(schema.oneOf) do
            local save_path = tablex.copy(path)
            local success, submsg = pcall(M.check, subschema, value, path)
            path = save_path
            if success then return end
            if i > 1 then
                msg = msg .. "; " .. submsg
            else
                msg = "All alternatives failed in " .. table.concat(path, '.') .. ": " .. submsg
            end
        end
        error(msg)

    elseif schema.type then
        if schema.type ~= type(value) then
            error(string.format('Type mismatch in %s expected: %s got: %s',
                table.concat(path, '.'),
                schema.type,
                type(value)
            ))
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
                    M.check(v, value[k], path)
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
                    status('schema', 'Unexpected field %s', table.concat(path, '.'))
                    table.remove(path)
                end
            end

        elseif schema.type == 'number' then
            local where = table.concat(path, '.')
            if schema.integer and math.tointeger(value) == nil then
                error(string.format('Expected an integer in %s got: %s', where, tostring(value)))
            end
            if schema.minimum and value < schema.minimum then
                error(string.format('Value in %s is below the minimum %s: %s',
                    where, tostring(schema.minimum), tostring(value)))
            end
            if schema.maximum and value > schema.maximum then
                error(string.format('Value in %s is above the maximum %s: %s',
                    where, tostring(schema.maximum), tostring(value)))
            end

        elseif schema.type == 'string' then
            if schema.pattern and not value:find(schema.pattern) then
                error(string.format('Pattern failure in %s',
                    table.concat(path, '.')
                ))
            end
        end
    end
end

return M
