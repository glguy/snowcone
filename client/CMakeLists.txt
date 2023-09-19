# set(CMAKE_CXX_CLANG_TIDY /usr/local/opt/llvm/bin/clang-tidy -checks=-*,readability-*)
add_executable(snowcone
    main.cpp app.cpp applib.cpp bracketed_paste.cpp
    safecall.cpp timer.cpp dnslookup.cpp
    irc/plain_connection.cpp irc/tls_connection.cpp irc/irc_connection.cpp irc/lua.cpp irc/socks.cpp
    )
target_link_libraries(snowcone PRIVATE
    PkgConfig::NCURSESW PkgConfig::LUA Boost::headers OpenSSL::SSL
    ircmsg myncurses mybase64 myopenssl)
configure_file(config.hpp.in config.hpp @ONLY)
target_include_directories(snowcone PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")

if(LIBHS_FOUND)
target_link_libraries(snowcone PRIVATE hsfilter)
endif()

if(LIBIDN_FOUND)
target_link_libraries(snowcone PRIVATE mystringprep)
endif()

install(TARGETS snowcone DESTINATION "${CMAKE_INSTALL_BINDIR}")
