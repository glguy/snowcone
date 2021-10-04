add_executable(snowcone
    main.c app.c socat.c buffer.c configuration.c
    irc.c tcp-server.c write.c read-line.c base64.c)

target_link_libraries(snowcone PRIVATE
    PkgConfig::UV PkgConfig::NCURSESW PkgConfig::LUA
    ircmsg mygeoip myncurses)

configure_file(config.h.in config.h @ONLY)
target_include_directories(snowcone PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")

install(TARGETS snowcone DESTINATION "${CMAKE_INSTALL_BINDIR}")
