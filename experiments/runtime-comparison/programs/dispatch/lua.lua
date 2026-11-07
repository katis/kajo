-- dispatch: one polymorphic call site (step) over three classes, read from
-- an array per iteration. Leaf inherits step from Adder.
local REPS = 100000000

local function class(super)
  local c = {}
  c.__index = c
  if super then setmetatable(c, { __index = super }) end
  return c
end

local Adder = class()
function Adder:step(n) return n + 1 end
local Leaf = class(Adder)
local Doubler = class()
function Doubler:step(n) return n + n end
local Subber = class()
function Subber:step(n) return n - 3 end

local arr = { setmetatable({}, Leaf), setmetatable({}, Doubler), setmetatable({}, Subber) }
local sum, k = 0, 1
for reps = REPS, 1, -1 do
  sum = sum + arr[k]:step(reps)
  k = k + 1
  if k > 3 then k = 1 end
end
print(string.format("%d", sum))
