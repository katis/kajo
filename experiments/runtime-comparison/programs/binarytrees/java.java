// binarytrees: one long-lived tree of depth 12, then REPS trees of depth 16
// built, checked and dropped.
class Main {
    static final int REPS = 1280;

    static final class Node {
        Node left, right;

        Node(int depth) {
            if (depth > 0) {
                left = new Node(depth - 1);
                right = new Node(depth - 1);
            }
        }

        long check() {
            return left == null ? 1 : left.check() + right.check() + 1;
        }
    }

    public static void main(String[] args) {
        Node longLived = new Node(12);
        long sum = 0;
        for (int reps = REPS; reps > 0; reps--) sum += new Node(16).check();
        System.out.println(sum + longLived.check());
    }
}
