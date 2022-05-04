#include "irc.hpp"

#include "app.hpp"
#include "configuration.hpp"
#include "read-line.hpp"
#include "socat.hpp"
#include "write.hpp"

#include <uv.h>

#include <cstring>

namespace {

void on_err_line(uv_stream_t* stream, char* line)
{
    if (line) {
        auto const a = static_cast<app*>(stream->loop->data);
        a->do_irc_err(line);
    }
}

void on_line(uv_stream_t* stream, char* line)
{
    auto const a = static_cast<app*>(stream->loop->data);

    if (line) {
        auto msg = strsep(&line, "\r\n");
        try {
            a->do_irc(parse_irc_message(msg));
        } catch (irc_parse_error const& e) {}
    } else {
        a->clear_irc();

        if (!a->closing)
        {
            auto timer = new uv_timer_t;
            uvok(uv_timer_init(&a->loop, timer));
            uvok(uv_timer_start(timer, [](auto timer) {
                auto const a = static_cast<app*>(timer->loop->data);
                uv_close_delete(timer);
                start_irc(a);
            }, 5000, 0));
        }
    }
}

} // namespace

int start_irc(app* a)
{
    if (auto pipes = socat_wrapper(&a->loop, a->cfg->irc_socat)) {
        auto [irc,err] = *pipes;
        a->set_irc(reinterpret_cast<uv_stream_t*>(irc));
        readline_start(irc, on_line);
        readline_start(err, on_err_line);
        return 0;
    } else {
        return 1;
    }
}
