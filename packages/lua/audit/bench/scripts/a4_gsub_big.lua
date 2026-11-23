local line = string.rep("alpha=1 beta=22 gamma=333 ", 4000)
local total = 0
for r = 1, 10 do
  local out, n = string.gsub(line, "(%a+)=(%d+)", "%2:%1")
  total = total + n + #out
end
local cnt = 0
for w in string.gmatch(line, "%a+") do cnt = cnt + 1 end
print(string.format("a4:%d:%d", total, cnt))
