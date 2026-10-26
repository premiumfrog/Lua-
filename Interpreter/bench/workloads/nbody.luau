local sqrt = math.sqrt
local bodies = {}
for i = 1, 5 do
	bodies[i] = { x = i, y = i * 2, z = i * 3, vx = 0, vy = 0, vz = 0, mass = i }
end
local function advance(dt)
	local n = #bodies
	for i = 1, n do
		local bi = bodies[i]
		local bix, biy, biz, bimass = bi.x, bi.y, bi.z, bi.mass
		local bivx, bivy, bivz = bi.vx, bi.vy, bi.vz
		for j = i + 1, n do
			local bj = bodies[j]
			local dx, dy, dz = bix - bj.x, biy - bj.y, biz - bj.z
			local d2 = dx * dx + dy * dy + dz * dz
			local mag = dt / (d2 * sqrt(d2))
			local bm = bj.mass * mag
			bivx -= dx * bm
			bivy -= dy * bm
			bivz -= dz * bm
			bm = bimass * mag
			bj.vx += dx * bm
			bj.vy += dy * bm
			bj.vz += dz * bm
		end
		bi.vx, bi.vy, bi.vz = bivx, bivy, bivz
		bi.x = bix + dt * bivx
		bi.y = biy + dt * bivy
		bi.z = biz + dt * bivz
	end
end
for i = 1, 60000 do
	advance(0.01)
end
return math.floor(bodies[1].x * 1000)
