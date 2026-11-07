// dispatch: one polymorphic call site (step) over three classes, read from
// an array per iteration. Leaf inherits step from Adder.
class Main {
    static final long REPS = 100_000_000L;

    abstract static class Stepper { abstract long step(long n); }
    static class Adder extends Stepper { long step(long n) { return n + 1; } }
    static class Leaf extends Adder {}
    static class Doubler extends Stepper { long step(long n) { return n + n; } }
    static class Subber extends Stepper { long step(long n) { return n - 3; } }

    public static void main(String[] args) {
        Stepper[] arr = { new Leaf(), new Doubler(), new Subber() };
        long sum = 0;
        int k = 0;
        for (long reps = REPS; reps > 0; reps--) {
            sum += arr[k].step(reps);
            if (++k > 2) k = 0;
        }
        System.out.println(sum);
    }
}
