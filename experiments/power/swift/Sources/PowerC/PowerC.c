#include "PowerC.h"

void kajo_wfe(void) {
#if defined(__arm64__) || defined(__aarch64__)
    __asm__ volatile("wfe" ::: "memory");
#endif
}

void kajo_yield(void) {
#if defined(__arm64__) || defined(__aarch64__)
    __asm__ volatile("yield" ::: "memory");
#endif
}
