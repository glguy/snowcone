pkg_search_module(CHECK IMPORTED_TARGET check>=0.11.0)

if (CHECK_FOUND)
add_executable(tests-ircmsg tests-ircmsg.c)
target_link_libraries(tests-ircmsg PRIVATE ircmsg)
target_link_libraries(tests-ircmsg PRIVATE PkgConfig::CHECK)
add_test(NAME tests-ircmsg COMMAND tests-ircmsg)
endif()

find_program(LUACHECK luacheck)
if(NOT ${LUACHECK} EQUAL "LUACHECK-NOTFOUND")
message("luacheck was " ${LUACHECK})
add_test(NAME luacheck
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}/lua"
  COMMAND ${LUACHECK} ".")
endif()
