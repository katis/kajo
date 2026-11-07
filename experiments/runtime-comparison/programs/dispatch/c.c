// dispatch: one polymorphic call site (step) over three kinds of object,
// read from an array per iteration. Leaf shares Adder's step.
#include <stdint.h>
#include <stdio.h>

#define REPS 100000000

typedef struct Obj Obj;
struct Obj { int64_t (*step)(const Obj *self, int64_t n); };

static int64_t adder_step(const Obj *self, int64_t n) { (void)self; return n + 1; }
static int64_t doubler_step(const Obj *self, int64_t n) { (void)self; return n + n; }
static int64_t subber_step(const Obj *self, int64_t n) { (void)self; return n - 3; }

int main(void) {
    Obj leaf = { adder_step }, doubler = { doubler_step }, subber = { subber_step };
    Obj *arr[3] = { &leaf, &doubler, &subber };
    int64_t sum = 0;
    int k = 0;
    for (int64_t reps = REPS; reps > 0; reps--) {
        Obj *o = arr[k];
        sum += o->step(o, reps);
        if (++k > 2) k = 0;
    }
    printf("%lld\n", (long long)sum);
    return 0;
}
