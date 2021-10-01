add_executable(tests-ircmsg tests-ircmsg.c)
target_link_libraries(tests-ircmsg PRIVATE ircmsg)

add_test(NAME tests-ircmsg COMMAND tests-ircmsg)