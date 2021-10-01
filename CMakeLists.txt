cmake_minimum_required(VERSION 3.13)
set(CMAKE_C_STANDARD 11)
enable_testing()

project(snowcone
    VERSION 1
    DESCRIPTION "IRC server notice console"
    HOMEPAGE_URL "https://github.com/glguy/snowcone"
    LANGUAGES C
)

add_subdirectory(ircmsg)
add_subdirectory(app)
add_subdirectory(tests)

install(DIRECTORY "lua" DESTINATION "share/snowcone")
