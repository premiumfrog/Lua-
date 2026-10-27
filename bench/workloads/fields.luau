local p = { x = 1, y = 2, z = 3 }
local s = 0
for i = 1, 1000000 do
	p.x = p.y + p.z
	p.y = p.x - i
	s += p.x
end
return s
