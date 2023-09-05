local class = require 'pl.class'

local LoadAverage = class()
LoadAverage._name = 'LoadAverage'

local exp_1  = 1 / math.exp(1/ 1/60)
local exp_5  = 1 / math.exp(1/ 5/60)
local exp_15 = 1 / math.exp(1/15/60)
local ticks = {[0]=' ','▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}

function LoadAverage:sample(x)
    self[ 1] = self[ 1] * exp_1  + x * (1 - exp_1 )
    self[ 5] = self[ 5] * exp_5  + x * (1 - exp_5 )
    self[15] = self[15] * exp_15 + x * (1 - exp_15)
    self.recent[self.n % 60 + 1] = x
    self.n = self.n + 1
end

function LoadAverage:graph()
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
end

function LoadAverage:_init()
    self[1] = 0
    self[5] = 0
    self[15] = 0
    self.recent = {}
    self.n = 0
end

return LoadAverage
