// arith: the sum of (i * 3 + 7) modulo 1000000007 over TOTAL iterations;
// the modulo is a conditional subtract.
class Main {
    static final long TOTAL = 320_000_000L;

    public static void main(String[] args) {
        long sum = 0;
        for (long i = 0; i < TOTAL; i++) {
            sum += i * 3 + 7;
            if (sum >= 1_000_000_007L) sum -= 1_000_000_007L;
        }
        System.out.println(sum);
    }
}
