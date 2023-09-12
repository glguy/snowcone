inc = include_directories('include')

libmystringprep = static_library('mystringprep',
    ['mystringprep.c'],
    include_directories: inc,
    dependencies: [liblua, libidn],
)

mystringprep = declare_dependency(
    include_directories: inc,
    dependencies: [liblua, libidn],
    link_with: [libmystringprep],
)
