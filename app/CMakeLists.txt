add_executable(snowcone
    main.c app.c socat.c configuration.c
    irc.c tcp-server.c write.c read-line.c base64.c
    lua_uv_timer.c lua_uv_filewatcher.c safecall.c)

target_link_libraries(snowcone PRIVATE
    PkgConfig::UV PkgConfig::NCURSESW PkgConfig::LUA
    ircmsg myncurses)

if(GEOIP_FOUND)
target_link_libraries(snowcone PRIVATE mygeoip)
endif()

configure_file(config.h.in config.h @ONLY)
target_include_directories(snowcone PRIVATE "${CMAKE_CURRENT_BINARY_DIR}" include)

install(TARGETS snowcone DESTINATION "${CMAKE_INSTALL_BINDIR}")
