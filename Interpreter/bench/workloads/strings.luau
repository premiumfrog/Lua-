local s = 0
local parts = {}
for i = 1, 100000 do
	local str = "item" .. i
	s += #str + string.byte(str, 1) + #string.sub(str, 2, 4)
	if i % 100 == 0 then
		parts[#parts + 1] = str:upper()
	end
end
return s + #table.concat(parts, ",")
