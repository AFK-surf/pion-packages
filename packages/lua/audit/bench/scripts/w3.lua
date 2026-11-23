local k = K
local t = {a = k, b = k * 3 + 7}
local function f(x) return x + t.a + t.b end
return f(k % 11)
