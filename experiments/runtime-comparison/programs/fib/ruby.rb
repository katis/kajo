# fib: recursive Fibonacci; REPS repetitions of fib(27 + r mod 2).
REPS = 960

def fib(n)
  n < 2 ? n : fib(n - 1) + fib(n - 2)
end

sum = 0
REPS.downto(1) { |r| sum += fib(27 + r % 2) }
puts sum
