add_library(mytoml STATIC parse_toml.cpp to_toml.cpp mytoml.cpp)
target_include_directories(mytoml PUBLIC include)
target_include_directories(mytoml PRIVATE toml11)
target_link_libraries(mytoml PRIVATE PkgConfig::LUA)
