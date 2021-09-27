include(FindPkgConfig)
find_package(PkgConfig REQUIRED)

pkg_check_modules(LUA      IMPORTED_TARGET lua>=5.3 lua5.3 lua-5.3 lua53 lua5.4 lua-5.4 lua54)
pkg_check_modules(UV       REQUIRED IMPORTED_TARGET libuv)
pkg_check_modules(NCURSESW REQUIRED IMPORTED_TARGET ncursesw)
pkg_check_modules(GEOIP    REQUIRED IMPORTED_TARGET geoip)

if(!LUA_FOUND)
  message(FATAL_ERROR "No Lua found")
endif()

add_executable(snowcone
    main.c app.c socat.c buffer.c configuration.c mygeoip.c
    ircmsg.c lua-ncurses.c irc.c tcp-server.c mrs.c write.c read-line.c)
target_link_libraries(snowcone PRIVATE PkgConfig::UV PkgConfig:LUA PkgConfig:NCURSESW PkgConfig:GEOIP)

install(TARGETS snowcone DESTINATION bin)
