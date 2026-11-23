local t = {}
for i = 1, 200000 do t[i * 1024] = i end
local s = 0
for i = 1, 200000 do s = s + t[i * 1024] end
print(string.format("a2:%d", s))
