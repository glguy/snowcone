---@meta
-- Types of the native globals hub uses, for the Lua Language Server.
-- Nothing loads this file; its declarations follow client/ and the my*
-- libraries.

-- snowcone ===========================================================

---@class snowcone.Message
---@field tags table<string, string> empty values are ''
---@field source string|nil
---@field command string|integer a numeric is an integer
---@field [integer] string arguments

---@class snowcone.Connection
local Connection = {}

--- Each returns true, or nil and 'connection closed' once closed.
---@param line string
---@return true|nil
---@return string|nil error
function Connection:send(line) end

---@return true|nil
---@return string|nil error
function Connection:close() end

---@class snowcone.Timer
local Timer = {}

--- Replaces any wait in progress. The callback runs at most once.
---@param ms integer
---@param callback fun()
function Timer:start(ms, callback) end

--- No callback from an earlier start runs after this.
function Timer:cancel() end

--- Handle of a DNS lookup or a child process. cancel drops its callback
--- and kills a child.
---@class snowcone.Cancellable
local Cancellable = {}
function Cancellable:cancel() end

---@class snowcone.Listener
local Listener = {}
function Listener:close() end

---@class snowcone.TlsLayer
---@field type 'tls'
---@field client_cert myopenssl.X509|nil
---@field client_key myopenssl.Pkey|nil
---@field verify string|nil name the certificate must match; '' disables verification
---@field sni string|nil
---@field alpn string[]|nil

---@class snowcone.ProxyLayer
---@field type 'socks'|'http'
---@field host string
---@field port integer
---@field username string|nil
---@field password string|nil

---@alias snowcone.Layer snowcone.TlsLayer|snowcone.ProxyLayer

---@class snowcone.ExecuteOptions
---@field input string|nil written to stdin; without it the child gets the terminal
---@field group boolean|nil own process group, so cancel kills descendants (needs input)
---@field max_output integer|nil bytes accepted on each of stdout and stderr

---@class snowcone.lib
---@field SIGINT integer
---@field SIGTSTP integer
snowcone = {}

--- Callback events: ('CON', fingerprint), ('MSG', message, redraw) and
--- ('END', error), where error is nil after a local close.
---@param host string socket path when port is 0
---@param port integer
---@param layers snowcone.Layer[]
---@param callback fun(event: 'CON'|'MSG'|'END', ...)
---@return snowcone.Connection
function snowcone.connect(host, port, layers, callback) end

--- The callback runs once: callback(nil, address...) or callback(error).
---@param hostname string
---@param callback fun(err: string|nil, ...: string)
---@return snowcone.Cancellable
function snowcone.dnslookup(hostname, callback) end

--- The callback runs once: callback(code, stdout, stderr) or
--- callback(nil, error).
---@param command string looked up in PATH without a directory
---@param args (string|number)[]
---@param callback fun(code: integer|nil, out: string, err: string|nil)
---@param options snowcone.ExecuteOptions|nil
---@return snowcone.Cancellable
function snowcone.execute(command, args, callback, options) end

--- The handler returns status, body and headers; no status gives a 500.
--- Errors are reported as handler(nil, what, message).
---@param host string
---@param service string
---@param handler fun(method: string|nil, target: string, body: string, headers: table<string, string>): integer|nil, string|nil, table<string, string>|nil
---@return snowcone.Listener
function snowcone.start_httpd(host, service, handler) end

---@return snowcone.Timer
function snowcone.newtimer() end

--- RFC 1459 upper case.
---@param s string
---@return string
function snowcone.irccase(s) end

---@param c integer
---@return boolean
function snowcone.isalnum(c) end

---@param line string without CR LF
---@return snowcone.Message|nil
---@return string|nil error
function snowcone.parse_irc(line) end

---@param tags string
---@return table<string, string>|nil
---@return string|nil error
function snowcone.parse_irc_tags(tags) end

--- Network-format bytes of a presentation-format address.
---@param address string
---@return string|nil
---@return string|nil error
function snowcone.pton(address) end

--- Seconds, with fractions, on a monotonic clock.
---@return number
function snowcone.monotime() end

---@return integer seconds
---@return integer nanoseconds
function snowcone.time() end

---@param signal integer
function snowcone.raise(signal) end

--- Signals SIGINT, SIGTERM and SIGHUP go to the module's on_signal.
---@param on boolean
function snowcone.catch_signals(on) end

--- The table whose callbacks the client calls.
---@param module any
function snowcone.setmodule(module) end

--- Take over the terminal and define ncurses, tty_width and tty_height.
function snowcone.start_ui() end

function snowcone.start_input() end
function snowcone.stop_input() end
function snowcone.shutdown() end

-- ncurses ============================================================

---@type integer
tty_width = 0
---@type integer
tty_height = 0

---@class ncurses.Window
local Window = {}

---@param ... string
function Window:waddstr(...) end

---@param y integer
---@param x integer
function Window:wmove(y, x) end

function Window:werase() end
function Window:wclear() end
function Window:delwin() end

---@param lines integer
---@param columns integer
function Window:wresize(lines, columns) end

---@param pminrow integer
---@param pmincol integer
---@param sminrow integer
---@param smincol integer
---@param smaxrow integer
---@param smaxcol integer
function Window:pnoutrefresh(pminrow, pmincol, sminrow, smincol, smaxrow, smaxcol) end

---@param pminrow integer
---@param pmincol integer
---@param sminrow integer
---@param smincol integer
---@param smaxrow integer
---@param smaxcol integer
function Window:prefresh(pminrow, pmincol, sminrow, smincol, smaxrow, smaxcol) end

--- Defined by snowcone.start_ui. A nil window means stdscr.
---@class ncurses.lib
---@field COLOR_BLACK integer
---@field COLOR_RED integer
---@field COLOR_GREEN integer
---@field COLOR_YELLOW integer
---@field COLOR_BLUE integer
---@field COLOR_MAGENTA integer
---@field COLOR_CYAN integer
---@field COLOR_WHITE integer
---@field COLOR_DEFAULT integer
---@field WA_NORMAL integer
---@field WA_BOLD integer
---@field WA_ITALIC integer
---@field WA_REVERSE integer
---@field WA_UNDERLINE integer
---@field [string] integer KEY_* codes
ncurses = {}

---@param lines integer
---@param columns integer
---@param y integer
---@param x integer
---@return ncurses.Window
function ncurses.newwin(lines, columns, y, x) end

---@param lines integer
---@param columns integer
---@return ncurses.Window
function ncurses.newpad(lines, columns) end

---@param win ncurses.Window|nil
---@return integer y
---@return integer x
function ncurses.getyx(win) end

---@param win ncurses.Window|nil
---@return integer lines
---@return integer columns
function ncurses.getmaxyx(win) end

--- Colours run from -1 (the default) to 7.
---@param fore integer|nil
---@param back integer|nil
---@param win ncurses.Window|nil
function ncurses.colorset(fore, back, win) end

---@param attrs integer
---@param win ncurses.Window|nil
function ncurses.attron(attrs, win) end

---@param attrs integer
---@param win ncurses.Window|nil
function ncurses.attroff(attrs, win) end

---@param attrs integer
---@param pair integer
---@param win ncurses.Window|nil
function ncurses.attrset(attrs, pair, win) end

---@param visibility integer
---@return integer previous
function ncurses.cursset(visibility) end

---@param win ncurses.Window|nil
function ncurses.erase(win) end

---@param win ncurses.Window|nil
function ncurses.clear(win) end

---@param win ncurses.Window|nil
function ncurses.noutrefresh(win) end

function ncurses.doupdate() end
function ncurses.beep() end
function ncurses.flash() end

-- myopenssl ==========================================================

---@class myopenssl.Digest
local Digest = {}

---@param data string
---@return string
function Digest:digest(data) end

---@param data string
---@param key string
---@return string
function Digest:hmac(data, key) end

---@return integer
function Digest:size() end

--- PBKDF2-HMAC with this digest.
---@param password string
---@param salt string
---@param iterations integer
---@param keylen integer
---@return string
function Digest:pbkdf2(password, salt, iterations, keylen) end

---@class myopenssl.Bignum
---@operator add(myopenssl.Bignum): myopenssl.Bignum
---@operator sub(myopenssl.Bignum): myopenssl.Bignum
---@operator mul(myopenssl.Bignum): myopenssl.Bignum
---@operator idiv(myopenssl.Bignum): myopenssl.Bignum
---@operator mod(myopenssl.Bignum): myopenssl.Bignum
---@operator pow(myopenssl.Bignum): myopenssl.Bignum
---@operator unm: myopenssl.Bignum

---@class myopenssl.Pkey
local Pkey = {}

--- The key's parameters by name: strings, or bignums for numbers.
---@return table<string, any>
function Pkey:export() end

---@param msg string
---@return string
function Pkey:sign(msg) end

---@param msg string
---@param padding 'oaep'|nil
---@return string
function Pkey:decrypt(msg, padding) end

---@param msg string
---@param padding 'oaep'|nil
---@return string
function Pkey:encrypt(msg, padding) end

---@param public myopenssl.Pkey
---@return string
function Pkey:derive(public) end

---@param cipher string|nil
---@param password string|nil
---@return string
function Pkey:to_private_pem(cipher, password) end

---@return string
function Pkey:to_public_pem() end

---@param key string
---@param value any
function Pkey:set_param(key, value) end

---@class myopenssl.X509
local X509 = {}

---@param version integer
function X509:set_version(version) end

---@param pubkey myopenssl.Pkey
function X509:set_pubkey(pubkey) end

---@return myopenssl.Pkey
function X509:get_pubkey() end

---@param pkey myopenssl.Pkey
---@param digest myopenssl.Digest|nil
function X509:sign(pkey, digest) end

---@param digest myopenssl.Digest
---@return string
function X509:fingerprint(digest) end

---@return string pem
function X509:export() end

---@param serial integer
function X509:set_serialNumber(serial) end

---@param notBefore string
function X509:set_notBefore(notBefore) end

---@param notAfter string
function X509:set_notAfter(notAfter) end

---@param name [string, string][] {field, value} pairs, in order
function X509:set_issuerName(name) end

---@param name [string, string][] {field, value} pairs, in order
function X509:set_subjectName(name) end

---@return [string, string][]
function X509:get_subjectName() end

---@param ca boolean
function X509:add_caConstraint(ca) end
function X509:add_clientUsageConstraint() end
function X509:add_serverUsageConstraint() end

---@param identifier string
function X509:add_subjectKeyIdentifier(identifier) end

---@param identifier string
function X509:add_authorityKeyIdentifier(identifier) end

---@class myopenssl.lib
---@field X509_VERSION_3 integer
---@field types table<string, integer> EVP_PKEY_* key types
myopenssl = {}

---@param name string
---@return myopenssl.Digest
function myopenssl.get_digest(name) end

--- 'RSA' takes a bit count; 'EC' a curve name.
---@param type string
---@param arg integer|string|nil
---@return myopenssl.Pkey
function myopenssl.gen_pkey(type, arg) end

---@param pem string
---@param private boolean
---@param password string|nil
---@return myopenssl.Pkey
function myopenssl.read_pem(pem, private, password) end

---@param type integer from myopenssl.types
---@param private boolean
---@param raw string
---@return myopenssl.Pkey
function myopenssl.read_raw(type, private, raw) end

--- A key named by an OpenSSL store URI.
---@param name string
---@param private boolean
---@param password string|nil
---@return myopenssl.Pkey
function myopenssl.pkey_from_store(name, private, password) end

---@return myopenssl.X509
function myopenssl.new_x509() end

---@param pem string
---@param password string|nil
---@return myopenssl.X509
function myopenssl.read_x509(pem, password) end

---@param n integer
---@return string bytes
function myopenssl.rand(n) end

---@param a string
---@param b string
---@return string
function myopenssl.xor(a, b) end

-- Others =============================================================

---@class mybase64.lib
mybase64 = {}

---@param s string
---@return string
function mybase64.to_base64(s) end

---@param s string
---@return string|nil nil when s is not base64
function mybase64.from_base64(s) end

---@class mytoml.lib
mytoml = {}

---@param text string
---@return table|nil
---@return string|nil error
function mytoml.parse_toml(text) end

-- Optional: nil when snowcone was built without the library.

---@class mystringprep.lib
local mystringprep_lib = {}

---@param s string
---@param profile string
---@return string
function mystringprep_lib.stringprep(s, profile) end

---@type mystringprep.lib|nil
mystringprep = mystringprep_lib

---@class mygeoip.Db
local GeoipDb = {}

---@param addr string
---@return string|nil
function GeoipDb:get_name_by_addr(addr) end

---@param addr string
---@return string|nil
function GeoipDb:get_name_by_addr_v6(addr) end

---@class mygeoip.lib
---@field GEOIP_ISP_EDITION integer
---@field GEOIP_ASNUM_EDITION_V6 integer
local mygeoip_lib = {}

---@param edition integer
---@return mygeoip.Db
function mygeoip_lib.open_db(edition) end

---@type mygeoip.lib|nil
mygeoip = mygeoip_lib
