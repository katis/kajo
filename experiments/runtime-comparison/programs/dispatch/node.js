// dispatch: one polymorphic call site (step) over three classes, read from
// an array per iteration. Leaf inherits step from Adder.
const REPS = 100000000;

class Adder { step(n) { return n + 1; } }
class Leaf extends Adder {}
class Doubler { step(n) { return n + n; } }
class Subber { step(n) { return n - 3; } }

const arr = [new Leaf(), new Doubler(), new Subber()];
let sum = 0;
let k = 0;
for (let reps = REPS; reps > 0; reps--) {
  sum += arr[k].step(reps);
  if (++k > 2) k = 0;
}
console.log(String(sum));
