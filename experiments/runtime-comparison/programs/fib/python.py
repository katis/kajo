# fib: recursive Fibonacci; REPS repetitions of fib(27 + r mod 2).
REPS = 960


def fib(n):
    return n if n < 2 else fib(n - 1) + fib(n - 2)


total = 0
for r in range(REPS, 0, -1):
    total += fib(27 + r % 2)
print(total)
