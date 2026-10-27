local function sum(...)
	local s = 0
	for i = 1, select("#", ...) do
		s += (select(i, ...))
	end
	return s
end
local function pass(...)
	return sum(...)
end
local function pack(...)
	local t = { ... }
	return #t
end
local s = 0
for i = 1, 100000 do
	s += pass(i, 2, 3, 4) + pack(i, i, i)
end
return s
