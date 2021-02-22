cmake_minimum_required (VERSION 3.16)
set(CMAKE_C_STANDARD 11)

project(snotecon)

add_executable(snote_con main.c app.c buffer.c)
target_link_libraries(snote_con PRIVATE lua5.3 uv dl)
