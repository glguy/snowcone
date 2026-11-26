-- mygeoip, when snowcone is built with libGeoIP: what open_db accepts, and
-- that a database is safe to use wrongly. With geoip-database installed,
-- the country database checks the edition guard; the lookups that need an
-- ISP or ASN database aren't tested, as no package provides one.
-- Run with:  snowcone tests/test-geoip.lua

if not mygeoip then
    print 'snowcone was built without libGeoIP; skipping'
    os.exit(77)
end

local function raises(pattern, f, ...)
    local ok, err = pcall(f, ...)
    assert(not ok, 'expected an error: ' .. pattern)
    assert(tostring(err):find(pattern, 1, true), err)
end

-- editions are integers naming one of libGeoIP's
raises('number has no integer representation', mygeoip.open_db, mygeoip.GEOIP_ISP_EDITION + 0.5)
raises('unknown edition', mygeoip.open_db, -1)
raises('unknown edition', mygeoip.open_db, 0)
raises('unknown edition', mygeoip.open_db, 1 << 40)
assert(mygeoip.GEOIP_COUNTRY_EDITION and mygeoip.GEOIP_ASNUM_EDITION_V6)

local ok, country = pcall(mygeoip.open_db, mygeoip.GEOIP_COUNTRY_EDITION)
if not ok then
    print('no country database (' .. tostring(country) .. '); skipping the rest')
    os.exit(0)
end

-- A country database has no names: libGeoIP would print to stdout
raises('get_name_by_addr: wrong database edition', country.get_name_by_addr, country, '192.0.2.1')
raises('get_name_by_addr_v6: wrong database edition', country.get_name_by_addr_v6, country, '2001:db8::1')

-- Closing twice is fine; a closed database raises instead of crashing
getmetatable(country).__close(country)
getmetatable(country).__close(country)
raises('database is closed', country.get_name_by_addr, country, '192.0.2.1')

print 'ok'
