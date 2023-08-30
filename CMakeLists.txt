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

pkg_search_module(LUA      REQUIRED IMPORTED_TARGET lua>=5.4 lua5.4 lua-5.4 lua54)
pkg_check_modules(NCURSESW REQUIRED IMPORTED_TARGET ncursesw>=6)
pkg_check_modules(UV       REQUIRED IMPORTED_TARGET libuv)
pkg_check_modules(GEOIP             IMPORTED_TARGET geoip)
pkg_check_modules(LIBHS             IMPORTED_TARGET libhs)
pkg_check_modules(LIBIDN            IMPORTED_TARGET libidn)

find_package(OpenSSL REQUIRED)
find_package(Boost REQUIRED)

if(GEOIP_FOUND)
add_subdirectory(mygeoip)
endif()

if(LIBHS_FOUND)
add_subdirectory(hsfilter)
endif()

if (LIBIDN_FOUND)
add_subdirectory(mystringprep)
endif()

add_subdirectory(ircmsg)
add_subdirectory(myncurses)
add_subdirectory(mybase64)
add_subdirectory(client)
add_subdirectory(docs)

if(BUILD_TESTING)
add_subdirectory(tests)
endif()

install(
    DIRECTORY   "ircc"
    DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/snowcone"
    PATTERN     ".luacheckrc" EXCLUDE)
install(
    DIRECTORY   "dashboard"
    DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/snowcone"
    PATTERN     ".luacheckrc" EXCLUDE)

install(FILES "snowcone.1" DESTINATION "${CMAKE_INSTALL_MANDIR}/man1")

set(CPACK_GENERATOR "DEB")
set(CPACK_DEBIAN_PACKAGE_MAINTAINER "Eric Mertens <emertens@gmail.com>")
set(CPACK_DEBIAN_PACKAGE_DEPENDS "libgeoip1, liblua5.4-0, libuv1, lua-penlight, socat")
include(CPack)
