local Vec = {}
Vec.__index = Vec
function Vec.new(x, y)
	return setmetatable({ x = x, y = y }, Vec)
end
function Vec:add(o)
	return Vec.new(self.x + o.x, self.y + o.y)
end
function Vec:len2()
	return self.x * self.x + self.y * self.y
end
local acc = Vec.new(0, 0)
local s = 0
for i = 1, 300000 do
	acc = acc:add(Vec.new(1, 2))
	s += acc:len2() % 7
end
return s
