local function gen(n)
	return coroutine.wrap(function()
		for i = 1, n do
			coroutine.yield(i)
		end
	end)
end
local s = 0
for r = 1, 100 do
	for v in gen(2000) do
		s += v
	end
end
return s
