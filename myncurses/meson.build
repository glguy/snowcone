inc = include_directories('include')

libmyncurses = static_library('myncurses',
    ['myncurses.c'],
    include_directories: inc,
    dependencies: [libncurses, liblua],
)

myncurses = declare_dependency(
    include_directories: inc,
    dependencies: [libncurses, liblua],
    link_with: [libmyncurses],
)
