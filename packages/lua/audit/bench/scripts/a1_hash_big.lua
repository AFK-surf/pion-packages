local t = {}
for i = 1, 200000 do t["key" .. i] = i end
local s = 0
for i = 1, 200000, 7 do s = s + t["key" .. i] end
local n = 0
for k, v in pairs(t) do n = n + 1 end
print(string.format("a1:%d:%d", s, n))
