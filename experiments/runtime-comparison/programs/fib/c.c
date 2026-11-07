// fib: recursive Fibonacci; REPS repetitions of fib(27 + r mod 2).
#include <stdint.h>
#include <stdio.h>

#define REPS 960

static int64_t fib(int64_t n) {
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

int main(void) {
    int64_t sum = 0;
    for (int64_t r = REPS; r > 0; r--) sum += fib(27 + r % 2);
    printf("%lld\n", (long long)sum);
    return 0;
}
