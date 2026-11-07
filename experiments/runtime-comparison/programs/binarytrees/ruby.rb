# binarytrees: one long-lived tree of depth 12, then REPS trees of depth 16
# built, checked and dropped.
REPS = 1280

class Node
  def initialize(depth)
    if depth > 0
      @left = Node.new(depth - 1)
      @right = Node.new(depth - 1)
    end
  end

  def check
    @left.nil? ? 1 : @left.check + @right.check + 1
  end
end

long_lived = Node.new(12)
sum = 0
REPS.times { sum += Node.new(16).check }
puts sum + long_lived.check
