#pragma once
/**
 * @file mygeoip.h
 * @brief Lua binding for organization/ISP/ASN lookups in legacy libGeoIP databases
 *
 */

#ifdef __cplusplus
extern "C" {
#endif

struct lua_State;

/**
 * @brief Lua module entry point: returns the mygeoip module table
 *
 * The table holds open_db(edition) and one integer field per libGeoIP
 * database edition, named after its C constant (GEOIP_ISP_EDITION, ...).
 *
 * open_db(edition) --> db opens the system database for that edition with
 * GeoIP_open_type and raises "Failed to open" if it cannot. An edition
 * that isn't an integer naming one of libGeoIP's editions is an argument
 * error.
 *
 * db methods (both return nil when there is no entry for the address, and
 * raise "<method>: wrong database edition" for an edition libGeoIP has no
 * such names in, rather than let it print over the screen):
 * * get_name_by_addr(addr): name for an IPv4 address in a non-V6 edition
 * * get_name_by_addr_v6(addr): name for an IPv6 address in a V6 edition
 *
 * __close and __gc both free the database; the second call does nothing.
 * A method called on a closed db raises an argument error.
 *
 * @param L Lua state
 * @return 1
 */
int luaopen_mygeoip(struct lua_State* L);

#ifdef __cplusplus
}
#endif
