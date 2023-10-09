local lexer = require 'pl.lexer'
local class = require 'pl.class'
local rex = require 'rex_pcre2'

local STRING1 = "^(['\"])%1" -- empty string
local STRING2 = [[^(['"])(\*)%2%1]]
local STRING3 = [[^(['"]).-[^\](\*)%2%1]]

local function stringlit(x)
    return 'string', string.sub(x,2, -2)
end

local matches = {
    {'^ +', 'space'},
    {'^%a+', function(word) return 'word', word end},
    {'^|[^|]*|I?', function(regex)
        print(regex)
        local flags
        if 'I' == string.sub(regex, -1) then
            flags = 'ix'
            regex = string.sub(regex, 2, -3)
        else
            flags = 'x'
            regex = string.sub(regex, 2, -2)
        end
        print('!', regex)
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

local Parser = class()
Parser._name = 'Parser'

function Parser:_init(s, fields)
    self.lexer = lexer.scan(s, matches, {space=true})
    self.fields = fields
    self:next()
end

function Parser:next()
    self.token, self.lexeme = self.lexer()
end

function Parser:failure(expected)
    local where = lexer.lineno(self.lexer)
    local got
    if self.lexeme then
        if type(self.token) == 'string' then
            got = self.lexeme
        else
            got = '`'..self.token..'`'
        end
    else
        got = '`end-of-input`'
    end

    error('Line ' .. where .. ' got ' .. got .. ' expected ' .. expected, 0)
end

function Parser:atom()
    if self.token == 'open' then
        self:next()
        local body = self:disjunct()
        if self.token == 'close' then
            self:next()
            return body
        else
            self:failure('`)`')
        end
    elseif self.token == 'word' then
        if self.lexeme == 'not' then
            self:next()
            local body = self:atom()
            return function(x) return not body(x) end
        else
            local field = self.fields[self.lexeme]
            if field then
                self:next()
                if self.token == 'regex' then
                    local r = self.lexeme
                    self:next()
                    return function(x)
                        return r:exec(x[field] or '') ~= nil
                    end
                elseif self.token == 'string' then
                    local s = self.lexeme
                    self:next()
                    return function(x)
                        return (x[field] or '') == s
                    end
                end
            end
        end
    end
    self:failure('a pattern')
end

function Parser:conjunct()
    local lhs = self:atom()
    if self.token == 'word' and self.lexeme == 'and' then
        self:next()
        local rhs = self:conjunct()
        return function(x) return lhs(x) and rhs(x) end
    else
        return lhs
    end
end

function Parser:disjunct()
    local lhs = self:conjunct()
    if self.token == 'word' and self.lexeme == 'or' then
        self:next()
        local rhs = self:disjunct()
        return function(x) return lhs(x) or rhs(x) end
    else
        return lhs
    end
end

function Parser:top()
    local result = self:disjunct()
    if self.token then
        self:failure('`end-of-input`')
    end
    return result
end


local clicon_fields = {
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

return function(s)
    local parser = Parser(s, clicon_fields)
    return parser:top()
end
