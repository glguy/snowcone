cmake_minimum_required(VERSION 3.13)
cmake_policy(SET CMP0135 NEW)
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
pkg_check_modules(GEOIP             IMPORTED_TARGET geoip)
pkg_check_modules(LIBHS             IMPORTED_TARGET libhs)
pkg_check_modules(LIBIDN            IMPORTED_TARGET libidn)

find_package(OpenSSL REQUIRED)

set(BOOST_INCLUDE_LIBRARIES asio endian system)
set(BOOST_ENABLE_CMAKE ON)
include(FetchContent)
FetchContent_Declare(
  Boost
  URL https://github.com/boostorg/boost/releases/download/boost-1.84.0/boost-1.84.0.tar.xz
  URL_HASH SHA1=938073443cc99490dff05288eb74c55ff424ca00
)
FetchContent_MakeAvailable(Boost)

if(GEOIP_FOUND)
add_subdirectory(mygeoip)
endif()

if(LIBHS_FOUND)
add_subdirectory(hsfilter)
endif()

if (LIBIDN_FOUND)
add_subdirectory(mystringprep)
endif()

add_subdirectory(mysocks5)
add_subdirectory(ircmsg)
add_subdirectory(myncurses)
add_subdirectory(mybase64)
add_subdirectory(myopenssl)
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
set(CPACK_DEBIAN_PACKAGE_DEPENDS "liblua5.4-0, lua-penlight, libssl3, libncursesw6, libidn12")
include(CPack)
