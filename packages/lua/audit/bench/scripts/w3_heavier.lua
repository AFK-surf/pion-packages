local k = K
local acc = 0
local cfg = {rate = k % 13, cap = 1000 + k}
local function clamp(v) if v > cfg.cap then return cfg.cap end return v end
for i = 1, 200 do acc = clamp(acc + i * cfg.rate) end
local parts = {}
for i = 1, 20 do parts[i] = string.format("%d", (acc + i) % 97) end
return acc + #table.concat(parts, ",")
