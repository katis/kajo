# dispatch: one polymorphic call site (step) over three classes, read from
# an array per iteration. Leaf inherits step from Adder.
REPS = 100_000_000

class Adder
  def step(n) = n + 1
end

class Leaf < Adder; end

class Doubler
  def step(n) = n + n
end

class Subber
  def step(n) = n - 3
end

arr = [Leaf.new, Doubler.new, Subber.new]
sum = 0
k = 0
reps = REPS
while reps > 0
  sum += arr[k].step(reps)
  k += 1
  k = 0 if k > 2
  reps -= 1
end
puts sum
