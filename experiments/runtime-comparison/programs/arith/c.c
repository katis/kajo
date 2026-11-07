// arith: the sum of (i * 3 + 7) modulo 1000000007 over TOTAL iterations;
// the modulo is a conditional subtract.
#include <stdint.h>
#include <stdio.h>

#define TOTAL 320000000

int main(void) {
    int64_t sum = 0;
    for (int64_t i = 0; i < TOTAL; i++) {
        sum += i * 3 + 7;
        if (sum >= 1000000007) sum -= 1000000007;
    }
    printf("%lld\n", (long long)sum);
    return 0;
}
