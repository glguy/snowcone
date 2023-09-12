conf_data = configuration_data()

conf_data.set('CMAKE_INSTALL_FULL_DATAROOTDIR', get_option('prefix') / get_option('datadir'))
conf_data.set('GEOIP_FOUND', libgeoip.found())
conf_data.set('LIBHS_FOUND', libhs.found())
conf_data.set('LIBIDN_FOUND', libidn.found())

configure_file(
    input: 'config.hpp.in',
    output: 'config.hpp',
    configuration: conf_data,
    format: 'cmake@')

executable('snowcone',
    ['app.cpp', 'applib.cpp', 'bracketed_paste.cpp', 'dnslookup.cpp',
     'irc.cpp', 'main.cpp', 'safecall.cpp', 'timer.cpp'],
     include_directories: ['include'],
     dependencies: [libboost, libssl, liblua, ircmsg, myopenssl, hsfilter, mybase64, mygeoip, mystringprep, myncurses],
     install: true,
     )
