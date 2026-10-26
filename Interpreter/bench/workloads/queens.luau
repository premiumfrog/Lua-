local N = 8
local count = 0
local cols, d1, d2 = {}, {}, {}
local function place(r)
	if r > N then
		count += 1
		return
	end
	for c = 1, N do
		if not cols[c] and not d1[r + c] and not d2[r - c + N] then
			cols[c], d1[r + c], d2[r - c + N] = true, true, true
			place(r + 1)
			cols[c], d1[r + c], d2[r - c + N] = false, false, false
		end
	end
end
for i = 1, 20 do
	place(1)
end
return count
