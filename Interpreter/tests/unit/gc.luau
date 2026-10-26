-- interpreter: debug-only
-- Values the guest no longer references are collectable, as on the host (weak tables observe this).

local weak = setmetatable({}, { __mode = "v" })
weak[1] = {}
local n = 0
while weak[1] do
	local garbage = {}
	n += 1
	assert(n < 10000000, "value was never collected")
end

-- a temporary read in a loop header does not pin the value
local holder = setmetatable({ [1] = {} }, { __mode = "kv" })
local A = 0
while holder[1] do
	local s = A .. A .. A .. A
	A += 1
	assert(A < 10000000, "temporary pinned the value")
end

-- a callee register left by a folded call does not pin the value
local cache = setmetatable({}, { __mode = "k" })
cache[{}] = true
collectgarbage()
assert(next(cache) == nil)

return "OK"
