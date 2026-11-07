# dispatch: one polymorphic call site (step) over three classes, read from
# a list per iteration. Leaf inherits step from Adder.
REPS = 100000000


class Adder:
    def step(self, n):
        return n + 1


class Leaf(Adder):
    pass


class Doubler:
    def step(self, n):
        return n + n


class Subber:
    def step(self, n):
        return n - 3


arr = [Leaf(), Doubler(), Subber()]
total = 0
k = 0
reps = REPS
while reps > 0:
    total += arr[k].step(reps)
    k += 1
    if k > 2:
        k = 0
    reps -= 1
print(total)
