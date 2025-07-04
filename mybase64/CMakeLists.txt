add_library(mybase64 STATIC mybase64.cpp)
target_include_directories(mybase64 PUBLIC include)
target_link_libraries(mybase64 PUBLIC base64 PkgConfig::LUA)

add_library(mybase64_shared SHARED mybase64.cpp)
set_target_properties(mybase64_shared PROPERTIES OUTPUT_NAME "mybase64" PREFIX "" SUFFIX ".so")
target_include_directories(mybase64_shared PUBLIC include)
target_link_libraries(mybase64_shared PUBLIC base64 PkgConfig::LUA)