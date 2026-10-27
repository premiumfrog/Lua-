local function counter()
	local n = 0
	return function()
		n += 1
		return n
	end
end
local s = 0
for i = 1, 20000 do
	local c = counter()
	for j = 1, 20 do
		s += c()
	end
end
return s
