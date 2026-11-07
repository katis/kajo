# arith: the sum of (i * 3 + 7) modulo 1000000007 over TOTAL iterations;
# the modulo is a conditional subtract.
TOTAL = 320000000

total = 0
i = 0
while i < TOTAL:
    total += i * 3 + 7
    if total >= 1000000007:
        total -= 1000000007
    i += 1
print(total)
