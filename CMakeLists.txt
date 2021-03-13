cmake_minimum_required(VERSION 3.13)
set(CMAKE_C_STANDARD 11)

project(snowcone
    VERSION 1
    DESCRIPTION "IRC server notice console"
    HOMEPAGE_URL "https://github.com/glguy/snowcone"
    LANGUAGES C
)

add_subdirectory(app)