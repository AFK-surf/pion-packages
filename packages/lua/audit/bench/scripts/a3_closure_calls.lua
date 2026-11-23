local function mk(n)
  local c = 0
  return function(x) c = c + x return c end
end
local fs = {}
for i = 1, 100 do fs[i] = mk(i) end
local s = 0
for r = 1, 20000 do
  for i = 1, 100, 9 do s = s + fs[i](r % 5) end
end
local function deep(n) if n == 0 then return 0 end return 1 + deep(n - 1) end
for i = 1, 3000 do s = s + deep(150) end
print(string.format("a3:%d", s))
