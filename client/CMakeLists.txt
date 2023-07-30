# set(CMAKE_CXX_CLANG_TIDY /usr/local/opt/llvm/bin/clang-tidy -checks=-*,readability-*)
add_executable(ircc
    main.cpp app.cpp applib.cpp bracketed_paste.cpp
    socat.cpp uv.cpp safecall.cpp irc.cpp
    lua_uv_timer.cpp lua_uv_dnslookup.cpp
    )

target_link_libraries(ircc PRIVATE
    PkgConfig::UV PkgConfig::NCURSESW PkgConfig::LUA
    ircmsg myncurses mybase64)
configure_file(config.hpp.in config.hpp @ONLY)
target_include_directories(ircc PRIVATE "${CMAKE_CURRENT_BINARY_DIR}" include)

install(TARGETS ircc DESTINATION "${CMAKE_INSTALL_BINDIR}")
