local M = {}

local exp_1  = 1 / math.exp(1/ 1/60)
local exp_5  = 1 / math.exp(1/ 5/60)
local exp_15 = 1 / math.exp(1/15/60)

local load_average_methods = {
    sample = function(self, x)
        self[ 1] = self[ 1] * exp_1  + x * (1 - exp_1 )
        self[ 5] = self[ 5] * exp_5  + x * (1 - exp_5 )
        self[15] = self[15] * exp_15 + x * (1 - exp_15)
        self.recent[self.n % 60 + 1] = x
        self.n = self.n + 1
    end,

    graph = function(self)
        local output = {}
        local j = 1
        local start = (self.n - 1) % 60 + 1
        for i = start, 1, -1 do
            output[j] = ticks[math.min(8, self.recent[i] or 0)]
            j = j + 1
        end
        for i = 60, start+1, -1 do
            output[j] = ticks[math.min(8, self.recent[i] or 0)]
            j = j + 1
        end
        return table.concat(output)
    end,
}

local load_average_mt = {
    __name = 'load_average',
    __index = load_average_methods,
}

function M.new()
    local o = {[1]=0, [5]=0, [15]=0, recent={}, n=0}
    setmetatable(o, load_average_mt)
    return o
end

return M