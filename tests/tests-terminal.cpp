// Runs the client on a pseudo-terminal: tests/terminal/*.lua report what
// the client's terminal layer delivers, one line per event on descriptor 3,
// and these tests compare that with the bytes they typed.

#include <gtest/gtest.h>

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#if __has_include(<pty.h>)
#include <pty.h>
#else
#include <util.h>
#endif

#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <vector>

namespace {

using namespace std::chrono_literals;
using steady = std::chrono::steady_clock;

auto check(int const result, char const* const what) -> int
{
    if (result == -1)
    {
        throw std::system_error{errno, std::generic_category(), what};
    }
    return result;
}

auto set_cloexec(int const fd) -> void
{
    check(::fcntl(fd, F_SETFD, FD_CLOEXEC), "fcntl");
}

#ifdef __APPLE__
constexpr char const* utf8_locale = "LC_ALL=en_US.UTF-8";
#else
constexpr char const* utf8_locale = "LC_ALL=C.UTF-8";
#endif

/// snowcone running a script on a terminal of its own
class Terminal
{
    pid_t pid_ = -1;
    int master_ = -1;
    int events_ = -1;
    std::string pending_; // event bytes read past the last line
    std::thread reader_;
    mutable std::mutex mutex_;
    std::string output_; // everything the client wrote to the terminal
    std::optional<int> status_;

public:
    explicit Terminal(std::string const& script, unsigned short const rows = 24, unsigned short const cols = 80)
    {
        int pipe[2];
        check(::pipe(pipe), "pipe");
        set_cloexec(pipe[0]);
        set_cloexec(pipe[1]);
        events_ = pipe[0];

        // Built before the fork: the child may only make async-signal-safe
        // calls
        std::string const path = SNOWCONE_PATH;
        std::string const file = std::string{TERMINAL_SCRIPTS} + "/" + script;
        char const* const argv[] = {path.c_str(), file.c_str(), nullptr};
        // PATH lets the sanitizers find their symbolizer
        std::string const path_env = std::string{"PATH="} + (std::getenv("PATH") ? std::getenv("PATH") : "/usr/bin:/bin");
        char const* const envp[] = {"TERM=xterm-256color", utf8_locale, "HOME=/nonexistent", path_env.c_str(), nullptr};

        winsize ws{};
        ws.ws_row = rows;
        ws.ws_col = cols;
        pid_ = check(::forkpty(&master_, nullptr, nullptr, &ws), "forkpty");
        if (pid_ == 0)
        {
            // dup2 clears close-on-exec on the copy
            if (::dup2(pipe[1], 3) == -1)
            {
                ::_exit(126);
            }
            ::execve(argv[0], const_cast<char* const*>(argv), const_cast<char* const*>(envp));
            ::_exit(127);
        }
        ::close(pipe[1]);
        set_cloexec(master_);

        // The client blocks once the terminal's buffer is full, so its
        // output is drained all along. The read fails (EIO on Linux) or
        // ends once the child has exited.
        reader_ = std::thread{[this] {
            char buffer[4096];
            for (;;)
            {
                auto const n = ::read(master_, buffer, sizeof buffer);
                if (n > 0)
                {
                    std::lock_guard lock{mutex_};
                    output_.append(buffer, n);
                }
                else if (n == 0 || errno != EINTR)
                {
                    return;
                }
            }
        }};
    }

    Terminal(Terminal const&) = delete;
    auto operator=(Terminal const&) -> Terminal& = delete;

    ~Terminal()
    {
        if (not status_)
        {
            ::kill(pid_, SIGKILL);
            int status;
            ::waitpid(pid_, &status, 0);
        }
        reader_.join();
        ::close(master_);
        ::close(events_);
    }

    /// Type bytes, as one write where the terminal takes them at once
    auto send(std::string_view bytes) -> void
    {
        while (not bytes.empty())
        {
            auto const n = ::write(master_, bytes.data(), bytes.size());
            if (n == -1 && errno == EINTR)
            {
                continue;
            }
            check(static_cast<int>(n), "write");
            bytes.remove_prefix(n);
        }
    }

    /// Change the terminal's size; the kernel sends SIGWINCH
    auto resize(unsigned short const rows, unsigned short const cols) -> void
    {
        winsize ws{};
        ws.ws_row = rows;
        ws.ws_col = cols;
        check(::ioctl(master_, TIOCSWINSZ, &ws), "TIOCSWINSZ");
    }

    /// The next event line, or nothing once the timeout passes or the
    /// script closes its end
    auto event(std::chrono::milliseconds const timeout = 5s) -> std::optional<std::string>
    {
        auto const deadline = steady::now() + timeout;
        for (;;)
        {
            if (auto const nl = pending_.find('\n'); nl != std::string::npos)
            {
                auto line = pending_.substr(0, nl);
                pending_.erase(0, nl + 1);
                return line;
            }
            auto const left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - steady::now());
            if (left <= 0ms)
            {
                return std::nullopt;
            }
            pollfd pfd{events_, POLLIN, 0};
            if (::poll(&pfd, 1, static_cast<int>(left.count())) <= 0)
            {
                continue;
            }
            char buffer[4096];
            auto const n = ::read(events_, buffer, sizeof buffer);
            if (n <= 0)
            {
                return std::nullopt;
            }
            pending_.append(buffer, n);
        }
    }

    /// The exit status, once the client exits within the timeout
    auto wait(std::chrono::milliseconds const timeout = 10s) -> std::optional<int>
    {
        auto const deadline = steady::now() + timeout;
        while (not status_ && steady::now() < deadline)
        {
            int status;
            if (check(::waitpid(pid_, &status, WNOHANG), "waitpid") == pid_)
            {
                status_ = status;
            }
            else
            {
                std::this_thread::sleep_for(10ms);
            }
        }
        return status_;
    }

    auto output() const -> std::string
    {
        std::lock_guard lock{mutex_};
        return output_;
    }

    /// Whether the client writes text to the terminal within the timeout
    auto wait_output(std::string_view const text, std::chrono::milliseconds const timeout = 5s) const -> bool
    {
        auto const deadline = steady::now() + timeout;
        while (output().find(text) == std::string::npos)
        {
            if (steady::now() >= deadline)
            {
                return false;
            }
            std::this_thread::sleep_for(10ms);
        }
        return true;
    }
};

/// What the client wrote, escaped, for failure messages
auto shown(std::string const& output) -> std::string
{
    std::string result;
    for (unsigned char const c : output)
    {
        if (c == '\n' || (0x20 <= c && c < 0x7f))
        {
            result += static_cast<char>(c);
        }
        else
        {
            char hex[5];
            std::snprintf(hex, sizeof hex, "\\x%02x", c);
            result += hex;
        }
    }
    return result;
}

/// Wait for each expected event in order
auto expect_events(Terminal& term, std::vector<std::string> const& expected) -> void
{
    for (auto const& want : expected)
    {
        auto const got = term.event();
        ASSERT_TRUE(got) << "no event; expected " << want << "\nterminal output:\n" << shown(term.output());
        ASSERT_EQ(want, *got);
    }
}

/// The client must exit successfully and leave the terminal as it found it
auto expect_clean_exit(Terminal& term) -> void
{
    auto const status = term.wait();
    ASSERT_TRUE(status) << "the client did not exit\n" << shown(term.output());
    auto const output = term.output();
    ASSERT_TRUE(WIFEXITED(*status) && WEXITSTATUS(*status) == 0) << "exit status " << *status << "\n" << shown(output);

    // Each mode turned on is turned off again later
    for (auto const& [on, off] : {
             std::pair{"\x1b[?1049h", "\x1b[?1049l"}, // alternate screen
             std::pair{"\x1b[?2004h", "\x1b[?2004l"}, // bracketed paste
             std::pair{"\x1b[?1004h", "\x1b[?1004l"}, // focus reporting
         })
    {
        auto const last_on = output.rfind(on);
        if (last_on != std::string::npos)
        {
            EXPECT_NE(std::string::npos, output.find(off, last_on)) << shown(on) << " left on\n" << shown(output);
        }
    }
}

/// End the client with ^D
auto finish(Terminal& term) -> void
{
    term.send("\x04");
    expect_clean_exit(term);
}

/// A client running tests/terminal/input.lua, ready for input
struct Input : testing::Test
{
    Terminal term{"input.lua"};

    void SetUp() override
    {
        expect_events(term, {"ready"});
    }
};

TEST_F(Input, Characters)
{
    term.send("a");
    term.send("Z");
    term.send(" ");
    expect_events(term, {"char a", "char Z", "key 32"});
    finish(term);
}

TEST_F(Input, ControlCharacters)
{
    // raw mode: ^C, ^Z and ^\ arrive as keys, not signals
    term.send("\x03");
    term.send("\x1a");
    term.send("\x1c");
    term.send("\r");
    term.send("\t");
    term.send("\x7f"); // xterm's backspace
    expect_events(term, {"key 3", "key 26", "key 28", "key 13", "key 9", "key KEY_BACKSPACE"});
    finish(term);
}

TEST_F(Input, CursesKeys)
{
    term.send("\x1bOA"); // xterm's keys in keypad mode
    term.send("\x1bOB");
    term.send("\x1b[5~");
    term.send("\x1b[6~");
    term.send("\x1bOP");
    term.send("\x1b[24~");
    term.send("\x1b[Z");
    term.send("\x1b[3~");
    expect_events(term, {"key KEY_UP", "key KEY_DOWN", "key KEY_PPAGE", "key KEY_NPAGE", "key KEY_F1", "key KEY_F12",
                         "key KEY_BTAB", "key KEY_DC"});
    finish(term);
}

TEST_F(Input, Alt)
{
    term.send("\x1b" "a");
    term.send("\x1b" "Z");
    term.send("\x1b" "1");
    expect_events(term, {"alt a", "alt Z", "alt 1"});
    finish(term);
}

TEST_F(Input, PlainEscape)
{
    // Esc alone arrives once the escape delay passes
    term.send("\x1b");
    expect_events(term, {"key 27"});
    term.send("a");
    expect_events(term, {"char a"});
    finish(term);
}

TEST_F(Input, Utf8)
{
    term.send("\xc3\xa9");
    term.send("\xe2\x82\xac");
    term.send("\xf0\x9f\x98\x80");
    expect_events(term, {"char \xc3\xa9", "char \xe2\x82\xac", "char \xf0\x9f\x98\x80"});
    finish(term);
}

TEST_F(Input, Utf8SplitAcrossWrites)
{
    term.send("\xe2");
    std::this_thread::sleep_for(50ms);
    term.send("\x82\xac");
    expect_events(term, {"char \xe2\x82\xac"});
    finish(term);
}

TEST_F(Input, InvalidUtf8)
{
    // Invalid bytes are dropped; what follows still arrives
    term.send("\xff");
    term.send("a");
    term.send("\xc3"); // a sequence cut short by ASCII
    term.send("b");
    term.send("\xa9");
    term.send("\xc3\xa9");
    expect_events(term, {"char a", "char b", "char \xc3\xa9"});
    finish(term);
}

TEST_F(Input, Paste)
{
    term.send("\x1b[200~hello world\x1b[201~");
    expect_events(term, {"paste 11 hello\\x20world"});
    finish(term);
}

TEST_F(Input, PasteKeepsEscapesAndControls)
{
    // Inside a paste nothing is decoded as a key
    term.send("\x1b[200~\x1bOA\x03\r\n\xc3\xa9\x1b[201~");
    expect_events(term, {"paste 8 \\x1bOA\\x03\\x0d\\x0a\\xc3\\xa9"});
    term.send("\x1bOA");
    expect_events(term, {"key KEY_UP"});
    finish(term);
}

TEST_F(Input, PasteEndSplitAcrossWrites)
{
    term.send("\x1b[200~abc\x1b[2");
    std::this_thread::sleep_for(50ms);
    term.send("01~");
    expect_events(term, {"paste 3 abc"});
    finish(term);
}

TEST_F(Input, EmptyPaste)
{
    term.send("\x1b[200~\x1b[201~");
    expect_events(term, {"paste 0 "});
    finish(term);
}

TEST_F(Input, PasteAtTheLimit)
{
    std::string const text(64 * 1024, 'x');
    term.send("\x1b[200~" + text + "\x1b[201~");
    expect_events(term, {"paste 65536 xxxxxxxx...xxxxxxxx"});
    finish(term);
}

TEST_F(Input, PasteOverTheLimit)
{
    std::string const text(64 * 1024 + 1, 'x');
    term.send("\x1b[200~" + text + "\x1b[201~");
    expect_events(term, {"discarded 65537"});
    term.send("\x1b[200~" + text + text + "\x1b[201~");
    expect_events(term, {"discarded 131074"});
    // input carries on as usual
    term.send("a");
    expect_events(term, {"char a"});
    finish(term);
}

TEST_F(Input, Focus)
{
    term.send("\x1b[I");
    term.send("\x1b[O");
    expect_events(term, {"key KEY_RESUME", "key KEY_EXIT"});
    finish(term);
}

TEST_F(Input, MouseClick)
{
    // A press and release together make a click; the encoding depends on
    // the mode ncurses asked for, which it may do only at the first read
    ASSERT_TRUE(term.wait_output("1000h")) << shown(term.output());
    if (term.output().find("\x1b[?1006") != std::string::npos)
    {
        term.send("\x1b[<0;11;4M\x1b[<0;11;4m");
        expect_events(term, {"mouse 3 10 false"});
        // ncurses makes clicks within its interval a double click
        std::this_thread::sleep_for(250ms);
        term.send("\x1b[<4;2;1M\x1b[<4;2;1m"); // with shift
    }
    else
    {
        term.send("\x1b[M\x20\x2b\x24\x1b[M\x23\x2b\x24");
        expect_events(term, {"mouse 3 10 false"});
        std::this_thread::sleep_for(250ms);
        term.send("\x1b[M\x24\x22\x21\x1b[M\x27\x22\x21");
    }
    expect_events(term, {"mouse 0 1 true"});
    finish(term);
}

TEST_F(Input, Resize)
{
    // Each is reported once, and nothing else arrives in between; the
    // first may come before the client takes SIGWINCH from ncurses
    term.resize(30, 100);
    expect_events(term, {"resize 100 30"});
    std::this_thread::sleep_for(100ms);
    term.resize(20, 60);
    expect_events(term, {"resize 60 20"});
    term.send("a");
    expect_events(term, {"char a"});
    finish(term);
}

TEST(Bindings, EveryCall)
{
    Terminal term{"bindings.lua"};
    std::string failures;
    for (;;)
    {
        auto const event = term.event();
        ASSERT_TRUE(event) << "no event\n" << failures << shown(term.output());
        if (*event == "done")
        {
            break;
        }
        failures += *event + "\n";
    }
    EXPECT_EQ("", failures);
    expect_clean_exit(term);
}

} // namespace
