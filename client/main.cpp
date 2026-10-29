#include "app.hpp"
#include "applib.hpp"
#include "config.hpp"
#include "safecall.hpp"

#include <csignal>
#include <cstring>
#include <iostream>

auto main(int argc, char const* argv[]) -> int
{
    if (argc < 2)
    {
        std::cerr << "Usage: snowcone PROGRAM [ARGS]\n"
                     "  Programs:\n"
                     "    hub                - multi-network client\n"
                     "    path/to/FILE.lua   - any Lua program\n"
                     "\n"
                     "  A program has no terminal until it calls snowcone.start_ui().\n"
                     "  snowcone exits once the program has no work left, and with a\n"
                     "  failure status after any uncaught Lua error.\n";
        return EXIT_FAILURE;
    }

    // A write to a pipe or socket whose reader is gone reports EPIPE instead
    // of killing the client. Child processes get the default back (process.cpp).
    std::signal(SIGPIPE, SIG_IGN);

    if (not strcmp("hub", argv[1]))
    {
        argv[1] = CMAKE_INSTALL_FULL_DATAROOTDIR "/snowcone/hub/init.lua";
    }

    auto a = App{argv[1]};
    auto const L = a.get_lua();

    auto loaded = false;
    try
    {
        prepare_globals(L, argc, argv);
        loaded = a.reload();
        if (loaded)
        {
            a.startup();
        }
    }
    catch (std::exception const& e)
    {
        App::fatal(e.what());
    }

    // A program fails if it couldn't load or any Lua error was reported
    if (not loaded or safecall_failures() > 0)
    {
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
