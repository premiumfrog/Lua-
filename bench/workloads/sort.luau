local seed = 42
local function rand()
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed
end
local s = 0
for r = 1, 10 do
	local t = {}
	for i = 1, 10000 do
		t[i] = rand() % 100000
	end
	table.sort(t, function(a, b)
		return a > b
	end)
	s += t[1] - t[#t]
end
return s
