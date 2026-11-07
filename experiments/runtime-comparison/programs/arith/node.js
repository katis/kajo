// arith: the sum of (i * 3 + 7) modulo 1000000007 over TOTAL iterations;
// the modulo is a conditional subtract.
const TOTAL = 320000000;

let sum = 0;
for (let i = 0; i < TOTAL; i++) {
  sum += i * 3 + 7;
  if (sum >= 1000000007) sum -= 1000000007;
}
console.log(String(sum));
