local arr, map = {}, {}
for i = 1, 1000 do
	arr[i] = i
	map["k" .. i] = i
end
local s = 0
for r = 1, 300 do
	for _, v in ipairs(arr) do
		s += v
	end
	for k, v in pairs(map) do
		s += v
	end
	for i, v in arr do
		s -= v
	end
end
return s
