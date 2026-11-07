// binarytrees: one long-lived tree of depth 12, then REPS trees of depth 16
// built, checked and dropped.
const REPS = 1280;

class Node {
  constructor(depth) {
    if (depth > 0) {
      this.left = new Node(depth - 1);
      this.right = new Node(depth - 1);
    } else {
      this.left = this.right = null;
    }
  }
  check() {
    return this.left === null ? 1 : this.left.check() + this.right.check() + 1;
  }
}

const longLived = new Node(12);
let sum = 0;
for (let reps = REPS; reps > 0; reps--) sum += new Node(16).check();
console.log(String(sum + longLived.check()));
