add_library(myhunspell STATIC myhunspell.c)
target_include_directories(myhunspell PUBLIC include)
target_link_libraries(myhunspell PkgConfig::LUA PkgConfig::HUNSPELL)
