add_library(myarchive STATIC myarchive.c)
target_include_directories(myarchive PUBLIC include)
target_link_libraries(myarchive PkgConfig::LUA PkgConfig::LIBARCHIVE)
