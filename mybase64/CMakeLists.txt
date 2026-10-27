add_library(mybase64 STATIC mybase64.cpp)
target_include_directories(mybase64 PUBLIC include)
target_link_libraries(mybase64 PUBLIC base64 PkgConfig::LUA)
