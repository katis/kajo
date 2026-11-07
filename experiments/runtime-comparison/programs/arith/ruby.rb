# arith: the sum of (i * 3 + 7) modulo 1000000007 over TOTAL iterations;
# the modulo is a conditional subtract.
TOTAL = 320_000_000

sum = 0
i = 0
while i < TOTAL
  sum += i * 3 + 7
  sum -= 1_000_000_007 if sum >= 1_000_000_007
  i += 1
end
puts sum
