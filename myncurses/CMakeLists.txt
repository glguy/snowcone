add_library(myncurses STATIC myncurses.c)
target_include_directories(myncurses PUBLIC include)
target_link_libraries(myncurses PkgConfig::LUA PkgConfig::NCURSESW)
