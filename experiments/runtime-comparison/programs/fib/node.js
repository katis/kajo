// fib: recursive Fibonacci; REPS repetitions of fib(27 + r mod 2).
const REPS = 960;

function fib(n) {
  return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

let sum = 0;
for (let r = REPS; r > 0; r--) sum += fib(27 + (r % 2));
console.log(String(sum));
