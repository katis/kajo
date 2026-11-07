# binarytrees: one long-lived tree of depth 12, then REPS trees of depth 16
# built, checked and dropped.
REPS = 1280


class Node:
    __slots__ = ("left", "right")

    def __init__(self, depth):
        if depth > 0:
            self.left = Node(depth - 1)
            self.right = Node(depth - 1)
        else:
            self.left = self.right = None

    def check(self):
        if self.left is None:
            return 1
        return self.left.check() + self.right.check() + 1


long_lived = Node(12)
total = 0
for _ in range(REPS):
    total += Node(16).check()
print(total + long_lived.check())
