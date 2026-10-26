local t = {}
for i = 1, 200000 do
	t[i] = i * 2
end
local s = 0
for r = 1, 10 do
	for i = 1, #t do
		s += t[i]
	end
end
return s
