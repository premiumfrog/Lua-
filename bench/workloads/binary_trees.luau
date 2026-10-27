local function make(d)
	if d == 0 then
		return { false, false }
	end
	d -= 1
	return { make(d), make(d) }
end
local function check(t)
	if not t[1] then
		return 1
	end
	return 1 + check(t[1]) + check(t[2])
end
local s = 0
for i = 1, 20 do
	s += check(make(12))
end
return s
