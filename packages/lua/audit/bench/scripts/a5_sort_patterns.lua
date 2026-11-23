local function check(t) for i = 2, #t do if t[i - 1] > t[i] then return 0 end end return 1 end
local ok = 0
local N = 50000
local asc, desc, same, saw = {}, {}, {}, {}
for i = 1, N do asc[i] = i desc[i] = N - i same[i] = 7 saw[i] = i % 100 end
table.sort(asc) table.sort(desc) table.sort(same) table.sort(saw)
ok = check(asc) + check(desc) + check(same) + check(saw)
local cmpn = 0
local r = {}
for i = 1, 20000 do r[i] = (i * 7919) % 20011 end
table.sort(r, function(a, b) cmpn = cmpn + 1 return a > b end)
print(string.format("a5:%d:%d", ok, r[1]))
