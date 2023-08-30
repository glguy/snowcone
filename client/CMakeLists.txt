# set(CMAKE_CXX_CLANG_TIDY /usr/local/opt/llvm/bin/clang-tidy -checks=-*,readability-*)
add_executable(ircc
    main.cpp app.cpp applib.cpp bracketed_paste.cpp
    safecall.cpp irc.cpp timer.cpp dnslookup.cpp
    )

target_link_libraries(ircc PRIVATE
    PkgConfig::NCURSESW PkgConfig::LUA Boost::headers OpenSSL::SSL
    ircmsg myncurses mybase64)
configure_file(config.hpp.in config.hpp @ONLY)
target_include_directories(ircc PRIVATE "${CMAKE_CURRENT_BINARY_DIR}" include)

if(LIBHS_FOUND)
target_link_libraries(ircc PRIVATE hsfilter)
endif()

if(LIBIDN_FOUND)
target_link_libraries(ircc PRIVATE mystringprep)
endif()

install(TARGETS ircc DESTINATION "${CMAKE_INSTALL_BINDIR}")
