-- A small query language for connection entries (from dashboard's
-- utils/matchdsl.lua), used by /prefilter.
--
--   query  := conj ('or' query)?
--   conj   := atom ('and' conj)?
--   atom   := '(' query ')' | 'not' atom | field |regex| | field |regex|I
--           | field 'string'
--
-- A field is one of the connection entry fields below. |regex| is PCRE2
-- extended syntax (|...|I ignores case) and needs rex_pcre2; 'string'
-- matches exactly.

local lexer <const> = require 'pl.lexer'
local has_rex, rex = pcall(require, 'rex_pcre2')

local STRING1 <const> = "^(['\"])%1" -- empty string
local STRING2 <const> = [[^(['"])(\*)%2%1]]
local STRING3 <const> = [[^(['"]).-[^\](\*)%2%1]]

local function stringlit(x)
    return 'string', x:sub(2, -2)
end

local matches <const> = {
    {'^ +', 'space'},
    {'^%a+', function(word) return 'word', word end},
    {'^|[^|]*|I?', function(regex)
        local flags
        if 'I' == regex:sub(-1) then
            flags = 'ix'
            regex = regex:sub(2, -3)
        else
            flags = 'x'
            regex = regex:sub(2, -2)
        end
        if not has_rex then
            return 'bad regex', 'regular expressions need rex_pcre2'
        end
        local success, result = pcall(rex.new, regex, flags)
        if success then
            return 'regex', result
        else
            return 'bad regex', result
        end
    end},
    {STRING1, stringlit},
    {STRING2, stringlit},
    {STRING3, stringlit},
    {'^%(', function(x) return 'open', x end},
    {'^%)', function(x) return 'close', x end},
    {'^.', function(x) return 'error', x end},
}

local fields <const> = {
    account = 'account',
    asn = 'asn',
    class = 'class',
    gecos = 'gecos',
    host = 'host',
    ip = 'ip',
    mask = 'mask',
    nick = 'nick',
    org = 'org',
    reason = 'reason',
    server = 'server',
    user = 'user',
}

--- Compile a query into a predicate on entries. Raises with a message
--- naming what was expected.
---@param s string
---@return function
return function(s)
    local scan = lexer.scan(s, matches, {space = true})
    local token, lexeme

    local function next_token()
        token, lexeme = scan()
    end

    local function failure(expected)
        local got
        if lexeme then
            if token == 'bad regex' then
                got = 'bad regex (' .. tostring(lexeme) .. ')'
            elseif type(token) == 'string' and token ~= 'word' then
                got = '`' .. token .. '`'
            else
                got = tostring(lexeme)
            end
        else
            got = '`end-of-input`'
        end
        error('got ' .. got .. ' expected ' .. expected, 0)
    end

    local disjunct

    local function atom()
        if token == 'open' then
            next_token()
            local body = disjunct()
            if token == 'close' then
                next_token()
                return body
            end
            failure('`)`')
        elseif token == 'word' then
            if lexeme == 'not' then
                next_token()
                local body = atom()
                return function(x) return not body(x) end
            end
            local field = fields[lexeme]
            if field then
                next_token()
                if token == 'regex' then
                    local r = lexeme
                    next_token()
                    return function(x)
                        return r:exec(tostring(x[field] or '')) ~= nil
                    end
                elseif token == 'string' then
                    local str = lexeme
                    next_token()
                    return function(x)
                        return tostring(x[field] or '') == str
                    end
                end
            end
        end
        failure('a pattern')
    end

    local function conjunct()
        local lhs = atom()
        if token == 'word' and lexeme == 'and' then
            next_token()
            local rhs = conjunct()
            return function(x) return lhs(x) and rhs(x) end
        end
        return lhs
    end

    function disjunct()
        local lhs = conjunct()
        if token == 'word' and lexeme == 'or' then
            next_token()
            local rhs = disjunct()
            return function(x) return lhs(x) or rhs(x) end
        end
        return lhs
    end

    next_token()
    local result = disjunct()
    if token then
        failure('`end-of-input`')
    end
    return result
end
