-- arith: the sum of (i * 3 + 7) modulo 1000000007 over TOTAL iterations;
-- the modulo is a conditional subtract.
local TOTAL = 320000000

local sum = 0
for i = 0, TOTAL - 1 do
  sum = sum + (i * 3 + 7)
  if sum >= 1000000007 then sum = sum - 1000000007 end
end
print(string.format("%d", sum))
