-- fib: recursive Fibonacci; REPS repetitions of fib(27 + r mod 2).
local REPS = 960

local function fib(n)
  if n < 2 then return n end
  return fib(n - 1) + fib(n - 2)
end

local sum = 0
for r = REPS, 1, -1 do sum = sum + fib(27 + r % 2) end
print(string.format("%d", sum))
