local count = 0
for r = 1, 30 do
	local flags = table.create(20000, true)
	count = 0
	for i = 2, 20000 do
		if flags[i] then
			count += 1
			for k = i + i, 20000, i do
				flags[k] = false
			end
		end
	end
end
return count
