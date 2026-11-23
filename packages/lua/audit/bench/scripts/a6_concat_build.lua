local total = 0
for r = 1, 100 do
  local parts = {}
  for i = 1, 1000 do parts[#parts + 1] = "item" .. i end
  total = total + #table.concat(parts, ";")
end
local acc = ""
for i = 1, 3000 do acc = acc .. "x" end
print(string.format("a6:%d:%d", total, #acc))
