local s = string.rep("abcdefghij", 5000)
local sum = 0
for i = 1, #s do sum = sum + s:byte(i) end
print(string.format("a7:%d:%d", #s, sum))
