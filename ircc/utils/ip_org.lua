local path = require 'pl.path'
local has_mmdb, mmdb = pcall(require, 'mmdb')
if has_mmdb then
    local success, geoip = pcall(mmdb.open, path.join(config_dir, 'GeoLite2-ASN.mmdb'))
    if success then
        return function(addr)
            local result
            if string.match(addr, '%.') then
                result = geoip:search_ipv4(addr)
            elseif string.match(addr, ':') then
                result = geoip:search_ipv6(addr)
            end
            if result then
                return result.autonomous_system_organization, result.autonomous_system_number
            end
        end
    end
end

if mygeoip then
    -- Other useful edition: mygeoip.GEOIP_ORG_EDITION, GEOIP_ISP_EDITION, GEOIP_ASNUM_EDITION
    local success4, geoip4 = pcall(mygeoip.open_db, mygeoip.GEOIP_ISP_EDITION)
    if not success4 then
        geoip4 = nil
    end

    local success6, geoip6 = pcall(mygeoip.open_db, mygeoip.GEOIP_ASNUM_EDITION_V6)
    if not success6 then
        geoip6 = nil
    end

    return function(addr)
        if geoip4 and string.match(addr, '%.') then
            return geoip4:get_name_by_addr(addr)
        end
        if geoip6 and string.match(addr, ':') then
            return geoip6:get_name_by_addr_v6(addr)
        end
    end
end

return function() end
