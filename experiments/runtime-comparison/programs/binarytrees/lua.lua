-- binarytrees: one long-lived tree of depth 12, then REPS trees of depth 16
-- built, checked and dropped.
local REPS = 1280

local function build(depth)
  if depth > 0 then
    return { left = build(depth - 1), right = build(depth - 1) }
  end
  return {}
end

local function check(node)
  if node.left == nil then return 1 end
  return check(node.left) + check(node.right) + 1
end

local longLived = build(12)
local sum = 0
for _ = 1, REPS do sum = sum + check(build(16)) end
print(string.format("%d", sum + check(longLived)))
