pkg_check_modules(CHECK REQUIRED IMPORTED_TARGET check)

add_executable(tests-ircmsg tests-ircmsg.c)
target_link_libraries(tests-ircmsg PRIVATE ircmsg)
target_link_libraries(tests-ircmsg PRIVATE PkgConfig::CHECK)

add_test(NAME tests-ircmsg COMMAND tests-ircmsg)
