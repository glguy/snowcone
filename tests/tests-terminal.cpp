// Runs the client on a pseudo-terminal: tests/terminal/*.lua report what
// the client's terminal layer delivers, one line per event on descriptor 3,
// and these tests compare that with the bytes they typed. libvterm keeps
// the screen the client draws, for the tests of what it shows.

#include <gtest/gtest.h>

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#include <vterm.h>

#if __has_include(<pty.h>)
#include <pty.h>
#else
#include <util.h>
#endif

#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <functional>
#include <mutex>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <vector>

extern char** environ;

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

/// A script in tests/terminal
auto script(std::string_view const name) -> std::string
{
    return std::string{TERMINAL_SCRIPTS} + "/" + std::string{name};
}

/// The environment for the client: this one (PATH lets the sanitizers find
/// their symbolizer, LUA_PATH finds Penlight) without what would change the
/// terminal or the configuration, then the given settings
auto client_environment(std::vector<std::string> const& extra) -> std::vector<std::string>
{
    std::vector<std::string> result;
    for (auto e = environ; *e; ++e)
    {
        std::string_view const entry{*e};
        auto const name = entry.substr(0, entry.find('='));
        if (name != "TERM" && name != "TERMINFO" && name != "LINES" && name != "COLUMNS" && name != "LANG"
            && not name.starts_with("LC_") && name != "HOME" && not name.starts_with("XDG_"))
        {
            result.emplace_back(entry);
        }
    }
    result.emplace_back("TERM=xterm-256color");
    result.emplace_back(utf8_locale);
    result.emplace_back("HOME=/nonexistent");
    result.insert(result.end(), extra.begin(), extra.end());
    return result;
}

/// The text of a cell as UTF-8
auto cell_text(VTermScreenCell const& cell) -> std::string
{
    std::string result;
    for (int i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i] != 0; ++i)
    {
        auto const c = cell.chars[i];
        if (c < 0x80)
        {
            result += static_cast<char>(c);
        }
        else if (c < 0x800)
        {
            result += static_cast<char>(0xc0 | c >> 6);
            result += static_cast<char>(0x80 | (c & 0x3f));
        }
        else if (c < 0x10000)
        {
            result += static_cast<char>(0xe0 | c >> 12);
            result += static_cast<char>(0x80 | (c >> 6 & 0x3f));
            result += static_cast<char>(0x80 | (c & 0x3f));
        }
        else
        {
            result += static_cast<char>(0xf0 | c >> 18);
            result += static_cast<char>(0x80 | (c >> 12 & 0x3f));
            result += static_cast<char>(0x80 | (c >> 6 & 0x3f));
            result += static_cast<char>(0x80 | (c & 0x3f));
        }
    }
    return result.empty() ? " " : result;
}

/// snowcone running a script on a terminal of its own
class Terminal
{
    pid_t pid_ = -1;
    int master_ = -1;
    int events_ = -1;
    std::string pending_; // event bytes read past the last line
    std::thread reader_;
    mutable std::mutex mutex_; // for output_, vterm_ and altscreen_
    std::string output_; // everything the client wrote to the terminal
    std::unique_ptr<VTerm, decltype(&vterm_free)> vterm_{nullptr, vterm_free};
    VTermScreen* screen_ = nullptr;
    bool altscreen_ = false;
    std::optional<int> status_;

    static auto settermprop(VTermProp const prop, VTermValue* const val, void* const user) -> int
    {
        if (prop == VTERM_PROP_ALTSCREEN)
        {
            static_cast<Terminal*>(user)->altscreen_ = val->boolean;
        }
        return 1;
    }

    static constexpr VTermScreenCallbacks callbacks{.settermprop = settermprop};

public:
    /// Run tests/terminal/<name> on a 24x80 terminal
    explicit Terminal(char const* const name)
        : Terminal{{script(name)}}
    {
    }

    /// Run snowcone with these arguments and settings added to its
    /// environment
    explicit Terminal(
        std::vector<std::string> const& args,
        unsigned short const rows = 24,
        unsigned short const cols = 80,
        std::vector<std::string> const& env = {})
    {
        vterm_.reset(vterm_new(rows, cols));
        vterm_set_utf8(vterm_.get(), 1);
        screen_ = vterm_obtain_screen(vterm_.get());
        vterm_screen_enable_altscreen(screen_, 1);
        vterm_screen_set_callbacks(screen_, &callbacks, this);
        vterm_screen_reset(screen_, 1);

        int pipe[2];
        check(::pipe(pipe), "pipe");
        set_cloexec(pipe[0]);
        set_cloexec(pipe[1]);
        events_ = pipe[0];

        // Built before the fork: the child may only make async-signal-safe
        // calls
        std::vector<std::string> arg_strings{SNOWCONE_PATH};
        arg_strings.insert(arg_strings.end(), args.begin(), args.end());
        std::vector<char const*> argv;
        for (auto const& a : arg_strings)
        {
            argv.push_back(a.c_str());
        }
        argv.push_back(nullptr);
        auto const env_strings = client_environment(env);
        std::vector<char const*> envp;
        for (auto const& e : env_strings)
        {
            envp.push_back(e.c_str());
        }
        envp.push_back(nullptr);

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
            ::execve(argv[0], const_cast<char* const*>(argv.data()), const_cast<char* const*>(envp.data()));
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
                    vterm_input_write(vterm_.get(), buffer, n);
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
        {
            std::lock_guard lock{mutex_};
            vterm_set_size(vterm_.get(), rows, cols);
        }
        winsize ws{};
        ws.ws_row = rows;
        ws.ws_col = cols;
        check(::ioctl(master_, TIOCSWINSZ, &ws), "TIOCSWINSZ");
    }

    auto signal(int const sig) const -> void
    {
        check(::kill(pid_, sig), "kill");
    }

    /// The terminal's modes, which the client sets on its side
    auto modes() const -> termios
    {
        termios t;
        check(::tcgetattr(master_, &t), "tcgetattr");
        return t;
    }

    /// Row y of the screen, without trailing blanks
    auto row(int const y) const -> std::string
    {
        std::lock_guard lock{mutex_};
        int rows, cols;
        vterm_get_size(vterm_.get(), &rows, &cols);
        std::string result;
        for (int x = 0; x < cols;)
        {
            VTermScreenCell cell;
            vterm_screen_get_cell(screen_, {.row = y, .col = x}, &cell);
            result += cell_text(cell);
            x += cell.width > 0 ? cell.width : 1;
        }
        return result.substr(0, result.find_last_not_of(' ') + 1);
    }

    /// The whole screen, for failure messages
    auto screen() const -> std::string
    {
        int rows, cols;
        {
            std::lock_guard lock{mutex_};
            vterm_get_size(vterm_.get(), &rows, &cols);
        }
        std::string result;
        for (int y = 0; y < rows; ++y)
        {
            result += "|" + row(y) + "\n";
        }
        return result;
    }

    auto cell(int const y, int const x) const -> VTermScreenCell
    {
        std::lock_guard lock{mutex_};
        VTermScreenCell cell;
        vterm_screen_get_cell(screen_, {.row = y, .col = x}, &cell);
        return cell;
    }

    auto altscreen() const -> bool
    {
        std::lock_guard lock{mutex_};
        return altscreen_;
    }

    /// Whether the condition holds within the timeout
    auto wait_until(std::function<bool()> const& condition, std::chrono::milliseconds const timeout = 5s) const -> bool
    {
        auto const deadline = steady::now() + timeout;
        while (not condition())
        {
            if (steady::now() >= deadline)
            {
                return false;
            }
            std::this_thread::sleep_for(10ms);
        }
        return true;
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
    auto wait_output(std::string_view const text) const -> bool
    {
        return wait_until([&] { return output().find(text) != std::string::npos; });
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

/// The terminal is as the client found it: each mode it turned on is
/// turned off again later
auto expect_restored(Terminal& term) -> void
{
    auto const output = term.output();
    EXPECT_FALSE(term.altscreen()) << term.screen();
    for (auto const& [on, off] : {
             std::pair{"\x1b[?2004h", "\x1b[?2004l"}, // bracketed paste
             std::pair{"\x1b[?1004h", "\x1b[?1004l"}, // focus reporting
             std::pair{"\x1b[?1000h", "\x1b[?1000l"}, // mouse
         })
    {
        auto const last_on = output.rfind(on);
        if (last_on != std::string::npos)
        {
            EXPECT_NE(std::string::npos, output.find(off, last_on)) << shown(on) << " left on\n" << shown(output);
        }
    }
    auto const modes = term.modes();
    EXPECT_TRUE(modes.c_lflag & ICANON) << "not in canonical mode";
    EXPECT_TRUE(modes.c_lflag & ECHO) << "not echoing";
}

/// The client must exit successfully and restore the terminal
auto expect_clean_exit(Terminal& term) -> void
{
    auto const status = term.wait();
    ASSERT_TRUE(status) << "the client did not exit\n" << shown(term.output());
    ASSERT_TRUE(WIFEXITED(*status) && WEXITSTATUS(*status) == 0) << "exit status " << *status << "\n" << shown(term.output());
    expect_restored(term);
}

/// The client must die of the signal and restore the terminal
auto expect_killed_by(Terminal& term, int const sig) -> void
{
    auto const status = term.wait();
    ASSERT_TRUE(status) << "the client did not exit\n" << shown(term.output());
    ASSERT_TRUE(WIFSIGNALED(*status) && WTERMSIG(*status) == sig) << "exit status " << *status << "\n" << shown(term.output());
    expect_restored(term);
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

/// A client running tests/terminal/screen.lua, drawn
struct Screen : testing::Test
{
    Terminal term{"screen.lua"};

    void SetUp() override
    {
        expect_events(term, {"drawn 80 24", "ready"});
        ASSERT_TRUE(term.wait_until([&] { return term.row(23) == "bottom 80x24"; })) << term.screen();
    }
};

TEST_F(Screen, Draws)
{
    EXPECT_TRUE(term.altscreen());
    EXPECT_EQ("hello", term.row(0));
    EXPECT_EQ("bold reverse red", term.row(1));
    EXPECT_TRUE(term.cell(1, 0).attrs.bold);
    EXPECT_FALSE(term.cell(1, 4).attrs.reverse);
    EXPECT_TRUE(term.cell(1, 5).attrs.reverse);
    EXPECT_FALSE(term.cell(1, 5).attrs.bold);
    auto const red = term.cell(1, 13).fg;
    EXPECT_TRUE(VTERM_COLOR_IS_INDEXED(&red) && red.indexed.idx == 1);
    auto const plain = term.cell(0, 0).fg;
    EXPECT_TRUE(VTERM_COLOR_IS_DEFAULT_FG(&plain));
    finish(term);
}

TEST_F(Screen, WideCharacters)
{
    EXPECT_EQ("wide: \u00e9\u20ac\U0001f600\u6f22\u5b57|", term.row(2));
    EXPECT_EQ(2, term.cell(2, 8).width);
    EXPECT_EQ("|", cell_text(term.cell(2, 14))) << term.screen();
    finish(term);
}

TEST_F(Screen, Resize)
{
    term.resize(30, 100);
    expect_events(term, {"drawn 100 30"});
    EXPECT_TRUE(term.wait_until([&] { return term.row(29) == "bottom 100x30"; })) << term.screen();
    term.resize(10, 40);
    expect_events(term, {"drawn 40 10"});
    EXPECT_TRUE(term.wait_until([&] { return term.row(9) == "bottom 40x10"; })) << term.screen();
    EXPECT_EQ("hello", term.row(0));
    finish(term);
}

TEST_F(Screen, StopInputGivesBackTheTerminal)
{
    term.send("s");
    expect_events(term, {"stopped"});
    EXPECT_TRUE(term.wait_until([&] { return not term.altscreen(); })) << term.screen();
    EXPECT_TRUE(term.modes().c_lflag & ICANON);
    EXPECT_TRUE(term.modes().c_lflag & ECHO);
    expect_events(term, {"drawn 80 24", "started"});
    EXPECT_TRUE(term.wait_until([&] { return term.altscreen() && term.row(0) == "hello"; })) << term.screen();
    EXPECT_FALSE(term.modes().c_lflag & ICANON);
    EXPECT_FALSE(term.modes().c_lflag & ECHO);
    finish(term);
}

TEST_F(Screen, SuspendWhereItCannotStop)
{
    // The client is the leader of its own session here, as under
    // tmux new-session or exec from a login shell: its process group is
    // orphaned, so the kernel discards SIGTSTP and the client carries on.
    // The screen must come back without a SIGCONT.
    term.send("z");
    EXPECT_TRUE(term.wait_until([&] { return term.altscreen() && term.row(23) == "bottom 80x24"; })) << term.screen();
    // and input carries on
    term.send("s");
    expect_events(term, {"stopped", "drawn 80 24", "started"});
    finish(term);
}

TEST_F(Screen, Sigterm)
{
    term.signal(SIGTERM);
    expect_killed_by(term, SIGTERM);
}

TEST(Error, ControlCStillEnds)
{
    Terminal term{"error.lua"};
    ASSERT_TRUE(term.wait_output("boom")) << shown(term.output());
    // With no module to take it, ^C raises SIGINT
    term.send("\x03");
    expect_killed_by(term, SIGINT);
    // the report stays on the screen
    EXPECT_NE(std::string::npos, term.screen().find("error.lua:7:")) << term.screen();
}

/// A directory of its own for the hub's configuration and saved state
struct TempDir
{
    std::string path;

    TempDir()
    {
        std::string templ = std::filesystem::temp_directory_path() / "snowcone-test.XXXXXX";
        path = ::mkdtemp(templ.data()) ? templ : throw std::system_error{errno, std::generic_category(), "mkdtemp"};
    }

    ~TempDir()
    {
        std::error_code ignored;
        std::filesystem::remove_all(path, ignored);
    }
};

/// hub, with tests/terminal/hub.toml
struct Hub : testing::Test
{
    TempDir config;
    Terminal term{
        {SOURCE_DIR "/hub/init.lua", "--config", script("hub.toml")},
        24,
        80,
        {"XDG_CONFIG_HOME=" + config.path}};
};

TEST_F(Hub, CommandLineHelpResizeAndQuit)
{
    auto const status = [&](int const row, std::string_view const text) {
        return term.wait_until([&] { return term.row(row).starts_with(text); });
    };
    std::string const sep = "\ue0b0"; // the status bar's powerline separator

    // With no networks it opens on the console
    ASSERT_TRUE(status(23, "console")) << term.screen();
    EXPECT_EQ("No network selected", term.row(0));

    // A paste goes into the command line
    term.send("/");
    ASSERT_TRUE(status(23, "console " + sep + " command")) << term.screen();
    term.send("\x1b[200~help\x1b[201~");
    ASSERT_TRUE(status(23, "console " + sep + " command " + sep + " help")) << term.screen();
    term.send("\r");
    ASSERT_TRUE(status(23, "help")) << term.screen();
    EXPECT_TRUE(term.row(0).starts_with("Commands")) << term.screen();

    // The help wraps at the terminal's width, and again after a resize
    auto const has_row = [&](std::string_view const text) {
        return term.wait_until([&] {
            for (int y = 0; y < 30; ++y)
            {
                if (term.row(y) == text) return true;
            }
            return false;
        });
    };
    EXPECT_TRUE(has_row(" CERT ADD command")) << term.screen();
    term.resize(30, 120);
    ASSERT_TRUE(status(29, "help")) << term.screen();
    EXPECT_TRUE(has_row("/cert_new $g         Make a self-signed client certificate and show its NickServ CERT ADD command"))
        << term.screen();

    term.send("/quit\r");
    expect_clean_exit(term);
}

} // namespace
