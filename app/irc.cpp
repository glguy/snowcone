#include "irc.hpp"

#include "app.hpp"
#include "configuration.hpp"
#include "read-line.hpp"
#include "socat.hpp"
#include "write.hpp"

#include <uv.h>

#include <cstring>

namespace {

void on_err_line(app* a, char* line)
{
    if (line) {
        a->do_irc_err(line);
    }
}

void on_line(app* a, char* line)
{
    if (line) {
        auto msg = strsep(&line, "\r\n");
        try {
            a->do_irc(parse_irc_message(msg));
        } catch (irc_parse_error const& e) {}
    } else {
        a->clear_irc();

        if (!a->closing) {
            uv_timer_start_xx(&a->reconnect, 5s, 0s, [](auto timer) {
                auto const a = static_cast<app*>(timer->loop->data);
                start_irc(a);
            });
        }
    }
}

} // namespace

int start_irc(app* a)
{
    if (auto pipes = socat_wrapper(&a->loop, a->cfg->irc_socat)) {
        auto [irc,err] = *pipes;
        a->set_irc(stream_cast(irc));
        readline_start(irc, on_line);
        readline_start(err, on_err_line);
        return 0;
    } else {
        return 1;
    }
}
