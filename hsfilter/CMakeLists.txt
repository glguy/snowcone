add_library(hsfilter STATIC hsfilter.cpp)
target_include_directories(hsfilter PUBLIC include)
target_link_libraries(hsfilter PRIVATE PkgConfig::LIBHS PkgConfig::LUA)
