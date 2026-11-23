package main

import (
	"fmt"
	"os"

	lua "github.com/yuin/gopher-lua"
)

const w1Script = `local function sieve(n)
  local is_p = {}
  for i = 2, n do is_p[i] = true end
  local i = 2
  while i * i <= n do
    if is_p[i] then
      for j = i * i, n, i do is_p[j] = false end
    end
    i = i + 1
  end
  local primes = {}
  local cnt = 0
  for k = 2, n do
    if is_p[k] then
      cnt = cnt + 1
      primes[cnt] = k
    end
  end
  return primes
end
local function fib(n)
  if n < 2 then return n end
  return fib(n - 1) + fib(n - 2)
end
local total = 0
for r = 1, 20 do
  local ps = sieve(4000)
  local arr = {}
  for i = 1, 250 do
    arr[i] = (ps[i] * 37 + r * 13) % 997
  end
  table.sort(arr)
  total = total + #ps + arr[1] + arr[125] + arr[250]
end
local f24 = fib(24)
print(string.format('w1:%d:%d', total, f24))
`

const w2Script = `local Rec = {}
Rec.__index = Rec
function Rec.new(id, score)
  return setmetatable({id = id, score = score}, Rec)
end
function Rec:__add(other)
  return Rec.new(self.id + other.id, self.score + other.score)
end
function Rec:render(tag)
  return string.format('[%s#%d=%d]', tag, self.id, self.score)
end
local function make_adder(base)
  local acc = base
  return function(d)
    acc = acc + d
    return acc
  end
end
local add = make_adder(0)
local line = 'user=alice score=42 role=admin; user=bob score=17 role=dev; user=carol score=88 role=ops'
local checksum = 0
local last = ''
for i = 1, 1500 do
  local transformed = string.gsub(line, '(%a+)=(%w+)', function(k, v)
    if k == 'score' then
      return k .. ':' .. tostring(tonumber(v) + (i % 7))
    end
    return k .. ':' .. string.upper(v)
  end)
  local sum = 0
  for num in string.gmatch(transformed, 'score:(%d+)') do
    sum = sum + tonumber(num)
  end
  local r = Rec.new(i, sum) + Rec.new(1, add(1) % 100)
  checksum = checksum + r.score
  if i == 1500 then last = r:render('OK') .. '|' .. transformed end
end
print(string.format('w2:%d:%s', checksum, last))
`

func main() {
	mode := "w1"
	if len(os.Args) >= 2 {
		mode = os.Args[1]
	}
	switch mode {
	case "w1":
		L := lua.NewState()
		defer L.Close()
		if err := L.DoString(w1Script); err != nil {
			fmt.Fprintf(os.Stderr, "ERR: %v\n", err)
			os.Exit(1)
		}
	case "w2":
		L := lua.NewState()
		defer L.Close()
		if err := L.DoString(w2Script); err != nil {
			fmt.Fprintf(os.Stderr, "ERR: %v\n", err)
			os.Exit(1)
		}
	case "w3", "w3_fair":
		fair := mode == "w3_fair"
		var acc int64
		for i := 1; i <= 2000; i++ {
			var L *lua.LState
			if fair {
				L = lua.NewState(lua.Options{SkipOpenLibs: true})
				for _, pair := range []struct {
					n string
					f lua.LGFunction
				}{
					{lua.BaseLibName, lua.OpenBase},
					{lua.TabLibName, lua.OpenTable},
					{lua.StringLibName, lua.OpenString},
					{lua.MathLibName, lua.OpenMath},
				} {
					L.Push(L.NewFunction(pair.f))
					L.Push(lua.LString(pair.n))
					L.Call(1, 0)
				}
			} else {
				L = lua.NewState()
			}
			script := fmt.Sprintf("local k = %d\nlocal t = {a = k, b = k * 3 + 7}\nlocal function f(x) return x + t.a + t.b end\nreturn f(k %% 11)\n", i)
			if err := L.DoString(script); err != nil {
				L.Close()
				fmt.Fprintf(os.Stderr, "ERR: %v\n", err)
				os.Exit(1)
			}
			v := L.Get(-1)
			if n, ok := v.(lua.LNumber); ok {
				acc += int64(n)
			}
			L.Close()
		}
		fmt.Printf("w3:2000:%d\n", acc)
	default:
		fmt.Fprintf(os.Stderr, "usage: go_lua <w1|w2|w3|w3_fair>\n")
		os.Exit(1)
	}
}
