inc = include_directories('include')

libmygeoip = static_library('mygeoip',
    ['mygeoip.c'],
    include_directories: inc,
    dependencies: [liblua, libgeoip],
)

mygeoip = declare_dependency(
    include_directories: inc,
    dependencies: [liblua, libgeoip],
    link_with: libmygeoip,
)
