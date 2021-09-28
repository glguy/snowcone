local has_mmdb, mmdb = pcall(require, 'mmdb')
if has_mmdb then
    local success, geoip = pcall(mmdb.open, 'GeoLite2-ASN.mmdb')
    if success then
        return function(addr)
            if string.match(addr, '%.') then
                local result = geoip:search_ipv4(addr)
                return result and result.autonomous_system_organization
            end
            if string.match(addr, ':') then
                local result = geoip:search_ipv6(addr)
                return result and result.autonomous_system_organization
            end
        end
    end
end

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
