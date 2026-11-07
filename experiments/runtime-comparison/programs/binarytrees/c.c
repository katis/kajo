// binarytrees: one long-lived tree of depth 12, then REPS trees of depth 16
// built, checked and freed. malloc and free per node.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define REPS 1280

typedef struct Node { struct Node *left, *right; } Node;

static Node *build(int depth) {
    Node *n = malloc(sizeof(Node));
    if (depth > 0) {
        n->left = build(depth - 1);
        n->right = build(depth - 1);
    } else {
        n->left = n->right = NULL;
    }
    return n;
}

static int64_t check(const Node *n) {
    return n->left == NULL ? 1 : check(n->left) + check(n->right) + 1;
}

static void release(Node *n) {
    if (n->left != NULL) { release(n->left); release(n->right); }
    free(n);
}

int main(void) {
    Node *longLived = build(12);
    int64_t sum = 0;
    for (int reps = REPS; reps > 0; reps--) {
        Node *t = build(16);
        sum += check(t);
        release(t);
    }
    printf("%lld\n", (long long)(sum + check(longLived)));
    release(longLived);
    return 0;
}
