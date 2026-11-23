local P = {} P.__index = P
function P.new(x, y) return setmetatable({x = x, y = y}, P) end
function P:add(o) return P.new(self.x + o.x, self.y + o.y) end
function P:len2() return self.x * self.x + self.y * self.y end
local acc = P.new(0, 0)
local s = 0
for i = 1, 200000 do acc = acc:add(P.new(i % 3, i % 5)) s = s + acc:len2() % 7 end
print(string.format("a8:%d:%d:%d", acc.x, acc.y, s))
