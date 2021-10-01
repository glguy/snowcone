add_library(mygeoip STATIC mygeoip.c)
target_include_directories(mygeoip PUBLIC include)
target_link_libraries(mygeoip PkgConfig::LUA PkgConfig::GEOIP)
