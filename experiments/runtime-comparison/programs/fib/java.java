// fib: recursive Fibonacci; REPS repetitions of fib(27 + r mod 2).
class Main {
    static final int REPS = 960;

    static long fib(long n) {
        return n < 2 ? n : fib(n - 1) + fib(n - 2);
    }

    public static void main(String[] args) {
        long sum = 0;
        for (int r = REPS; r > 0; r--) sum += fib(27 + r % 2);
        System.out.println(sum);
    }
}
