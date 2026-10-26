local s = 0
for i = 1, 500000 do
	local x = i * 0.37
	s += math.floor(x) + math.abs(-x) + math.max(i, 100) + math.sqrt(i)
	s = s % 1000000
end
return math.floor(s)
