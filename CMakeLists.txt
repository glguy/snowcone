cmake_minimum_required(VERSION 3.13)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 20)
project(snowcone
    VERSION 1
    DESCRIPTION "IRC server notice console"
    HOMEPAGE_URL "https://github.com/glguy/snowcone"
    LANGUAGES C CXX
)

include(GNUInstallDirs)
include(CTest)
find_package(PkgConfig REQUIRED)

pkg_search_module(LUA      REQUIRED IMPORTED_TARGET lua>=5.3 lua5.3 lua-5.3 lua53 lua5.4 lua-5.4 lua54)
pkg_check_modules(NCURSESW REQUIRED IMPORTED_TARGET ncursesw)
pkg_check_modules(UV       REQUIRED IMPORTED_TARGET libuv)
pkg_check_modules(GEOIP             IMPORTED_TARGET geoip)

if(GEOIP_FOUND)
add_subdirectory(mygeoip)
endif()

add_subdirectory(ircmsg)
add_subdirectory(myncurses)
add_subdirectory(mybase64)
add_subdirectory(app)

if(BUILD_TESTING)
add_subdirectory(tests)
endif()

install(
    DIRECTORY   "lua"
    DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/snowcone"
    PATTERN     ".luacheckrc" EXCLUDE)
install(FILES "snowcone.1" DESTINATION "${CMAKE_INSTALL_MANDIR}/man1")

set(CPACK_GENERATOR "DEB")
set(CPACK_DEBIAN_PACKAGE_MAINTAINER "Eric Mertens <glguy@libera.chat>")
set(CPACK_DEBIAN_PACKAGE_DEPENDS "libgeoip1, liblua5.3-0, libuv1, lua-penlight, socat")
include(CPack)
