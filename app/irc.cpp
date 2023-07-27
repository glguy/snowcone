#include "irc.hpp"

#include "app.hpp"
#include "configuration.hpp"
#include "read-line.hpp"
#include "socat.hpp"
#include "uv.hpp"

#include <ircmsg.hpp>

#include <uv.h>

#include <sstream>

namespace {

void on_err_line(app* a, char* line) {
    a->do_irc_err(line);
}

void on_line(app* a, char* line)
{
    try {
        while (*line == ' ') {
            line++;
        }
        if (*line != '\0') {
            a->do_irc(parse_irc_message(line));
        }
    } catch (irc_parse_error const& e) {
        std::stringstream msg;
        msg << "parse_irc_message failed: " << e.code;
        a->do_irc_err(msg.str().c_str());
    }
}

void on_done(app* a) {
    a->clear_irc();

    if (!a->closing) {
        uv_timer_start_xx(&a->reconnect, a->next_delay(), 0s, [](auto timer) {
            start_irc(app::from_loop(timer->loop));
        });
    }
}

} // namespace

void start_irc(app* a)
{
    try {
        auto [irc,err] = socat_wrapper(&a->loop, a->cfg.irc_socat);
        auto delete_pipe = [](uv_handle_t* h) { delete reinterpret_cast<uv_pipe_t*>(h); };
        a->set_irc(stream_cast(irc));
        readline_start(stream_cast(irc), on_line, on_done, delete_pipe);
        readline_start(stream_cast(err), on_err_line, [](auto){}, delete_pipe);
    } catch (UV_error const& e) {
        std::stringstream msg;
        msg << "socat spawn failed: " << e.what();
        a->do_irc_err(msg.str().c_str());
    }
}
