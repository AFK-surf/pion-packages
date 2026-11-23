-- Reference oracle (PUC-Rio Lua 5.4.x): same output protocol as audit/driver.
-- Each file runs in a fresh _ENV copy of the stdlib subset; print() is captured to a buffer.
for _, path in ipairs(arg) do
  io.write("## ", path, "\n")
  local f = assert(io.open(path, "rb")); local src = f:read("a"); f:close()
  local buf = {}
  local env = setmetatable({}, {__index = _G})
  env.print = function(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = tostring((select(i, ...))) end
    buf[#buf + 1] = table.concat(parts, "\t") .. "\n"
  end
  local fn, cerr = load(src, "=" .. path, "t", env)
  local ok, err
  if not fn then ok, err = false, cerr else ok, err = pcall(fn) end
  local out = table.concat(buf)
  io.write(out)
  if #out > 0 and out:sub(-1) ~= "\n" then io.write("\n") end
  if ok then io.write("=> OK\n") else io.write("=> ERR\n#msg ", tostring(err), "\n") end
  -- restore string metatable mutations between cases
end
