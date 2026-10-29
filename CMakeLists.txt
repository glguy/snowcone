cmake_minimum_required(VERSION 3.25)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

project(snowcone
    VERSION 1
    DESCRIPTION "IRC server notice console"
    HOMEPAGE_URL "https://github.com/glguy/snowcone"
    LANGUAGES C CXX
)

include(GNUInstallDirs)

# AddressSanitizer and UndefinedBehaviorSanitizer for every target; any
# report fails the run. Leak checking comes with ASan on Linux only.
option(SNOWCONE_SANITIZE "Build with ASan and UBSan" OFF)
if(SNOWCONE_SANITIZE)
    add_compile_options(-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
    add_link_options(-fsanitize=address,undefined)
endif()
include(CTest)
find_package(PkgConfig REQUIRED)

pkg_search_module(LUA      REQUIRED IMPORTED_TARGET lua>=5.4 lua5.4 lua-5.4 lua54)
pkg_check_modules(NCURSESW REQUIRED IMPORTED_TARGET ncursesw>=6)
pkg_check_modules(GEOIP             IMPORTED_TARGET geoip)
pkg_check_modules(LIBHS             IMPORTED_TARGET libhs)
pkg_check_modules(LIBIDN            IMPORTED_TARGET libidn)
pkg_check_modules(LIBARCHIVE        IMPORTED_TARGET libarchive)

find_package(OpenSSL REQUIRED)

find_package(Boost 1.83.0 CONFIG COMPONENTS process)
if(Boost_FOUND)
    set(BOOST_TARGETS Boost::headers)

    # In boost-1.86 process became a compile library, and its filesystem
    # choice is fixed by how it was built; before that, it is ours to make
    if(Boost_VERSION VERSION_GREATER_EQUAL 1.86)
        list(APPEND BOOST_TARGETS Boost::process)
    else()
        add_compile_definitions(BOOST_PROCESS_USE_STD_FS)
    endif()
else()
    set(BOOST_INCLUDE_LIBRARIES asio beast endian process system)
    set(BOOST_PROCESS_USE_STD_FS ON)
    set(BOOST_ENABLE_CMAKE ON)
    include(FetchContent)
    FetchContent_Declare(
    Boost
    URL https://github.com/boostorg/boost/releases/download/boost-1.92.0/boost-1.92.0-cmake.tar.gz
    URL_HASH SHA256=f51707c27359a0df0cac1beada86de31bb5eed5e8285592dadec384df99c2984
    )
    FetchContent_MakeAvailable(Boost)
    set(BOOST_TARGETS Boost::asio Boost::beast Boost::endian Boost::process)
endif()

if(GEOIP_FOUND)
add_subdirectory(mygeoip)
endif()

if(LIBHS_FOUND)
add_subdirectory(hsfilter)
endif()

if (LIBIDN_FOUND)
add_subdirectory(mystringprep)
endif()

if (LIBARCHIVE_FOUND)
add_subdirectory(myarchive)
endif()

add_subdirectory(base64)
add_subdirectory(ircmsg)
add_subdirectory(myncurses)
add_subdirectory(mybase64)
add_subdirectory(myopenssl)
add_subdirectory(mytoml)
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
install(
    DIRECTORY   "hub"
    DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/snowcone"
    PATTERN     ".luacheckrc" EXCLUDE
    PATTERN     "types.lua" EXCLUDE)

install(FILES "snowcone.1" DESTINATION "${CMAKE_INSTALL_MANDIR}/man1")

set(CPACK_GENERATOR "DEB")
set(CPACK_DEBIAN_PACKAGE_MAINTAINER "Eric Mertens <emertens@gmail.com>")
# dpkg-shlibdeps finds the shared libraries this build linked, optional ones
# included; Penlight is loaded at run time, so it is named here
set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)
set(CPACK_DEBIAN_PACKAGE_DEPENDS "lua-penlight")
# Loaded only where used: the legacy dashboard and ircc (rex_pcre2), IP
# organisations from GeoLite2 (mmdb), the GitHub plugin (json)
set(CPACK_DEBIAN_PACKAGE_RECOMMENDS "lua-rex-pcre2, lua-mmdb, lua-json")
# The version counts commits when cpack runs (cmake/CPackProjectConfig.cmake),
# and the file name follows it: snowcone_<version>_<arch>.deb
find_package(Git QUIET)
set(CPACK_SNOWCONE_GIT "${GIT_EXECUTABLE}")
set(CPACK_SNOWCONE_SOURCE_DIR "${PROJECT_SOURCE_DIR}")
set(CPACK_PROJECT_CONFIG_FILE "${PROJECT_SOURCE_DIR}/cmake/CPackProjectConfig.cmake")
set(CPACK_DEBIAN_FILE_NAME DEB-DEFAULT)
include(CPack)
