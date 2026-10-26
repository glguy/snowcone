-- The organisation and AS number of an address (from dashboard's
-- utils/ip_org.lua): MaxMind's GeoLite2-ASN.mmdb in the configuration
-- directory through the optional mmdb library, else the legacy GeoIP
-- databases through mygeoip, else nothing.

local path   <const> = require 'pl.path'
local config <const> = require 'hub.runtime.config'

local M = {}

-- Opened once per generation, when first needed
local lookup_impl

local function open()
    local has_mmdb, mmdb = pcall(require, 'mmdb')
    if has_mmdb then
        local ok, db = pcall(mmdb.open, path.join(config.config_dir(), 'GeoLite2-ASN.mmdb'))
        if ok then
            return function(addr)
                local result
                if addr:find '%.' then
                    result = db:search_ipv4(addr)
                elseif addr:find ':' then
                    result = db:search_ipv6(addr)
                end
                if result then
                    return result.autonomous_system_organization, result.autonomous_system_number
                end
            end
        end
    end

    if mygeoip then
        local ok4, geoip4 = pcall(mygeoip.open_db, mygeoip.GEOIP_ISP_EDITION)
        local ok6, geoip6 = pcall(mygeoip.open_db, mygeoip.GEOIP_ASNUM_EDITION_V6)
        if not ok4 then geoip4 = nil end
        if not ok6 then geoip6 = nil end
        return function(addr)
            if geoip4 and addr:find '%.' then
                return geoip4:get_name_by_addr(addr)
            end
            if geoip6 and addr:find ':' then
                return geoip6:get_name_by_addr_v6(addr)
            end
        end
    end

    return function() end
end

--- Replace the lookup, for tests; nil goes back to the databases.
function M.set_impl(f)
    lookup_impl = f
end

--- Organisation and AS number of an address, when known.
---@param addr string
---@return string|nil org, integer|nil asn
function M.lookup(addr)
    if lookup_impl == nil then
        lookup_impl = open()
    end
    return lookup_impl(addr)
end

return M
