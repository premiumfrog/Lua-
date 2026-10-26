local i, acc = 0, 0
while i < 2000000 do
	i += 1
	if i % 3 == 0 then
		acc += 1
	elseif i % 5 == 0 then
		acc -= 1
	end
end
return acc
