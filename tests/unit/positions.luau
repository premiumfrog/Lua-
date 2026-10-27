-- interpreter: debug-only
-- Error positions for errors the host raises inside handlers (arithmetic, calls, indexing) match native.

local function catch(f, ...)
	local ok, err = pcall(f, ...)
	assert(not ok)
	return err
end

local function line(err)
	return tonumber(string.match(err, "positions%.luau:(%d+):"))
end

local t = {}
assert(line(catch(function() return t.x.y end)) == 15)
assert(line(catch(function() return nil + 1 end)) == 16)
assert(line(catch(function() t.missing() end)) == 17)
assert(line(catch(function() return #nil end)) == 18)
assert(line(catch(function() return {} < {} end)) == 19)
assert(line(catch(function() return "a" .. {} end)) == 20)
assert(line(catch(function() error("boom") end)) == 21)
assert(line(catch(function() assert(false, "nope") end)) == 22)
assert(line(catch(function() t:method() end)) == 23)

-- across interpreted calls the position is the frame that failed
local function inner(v)
	return v.field
end
local function outer()
	return inner(nil)
end
assert(line(catch(outer)) == 27)

-- non-string errors and level 0 messages are passed through untouched
local sentinel = {}
assert(catch(function() error(sentinel) end) == sentinel)
assert(catch(function() error("bare", 0) end) == "bare")

-- messages already positioned by guest code keep their position
assert(line(catch(function() error("x", 1) end)) == 40)

return "OK"
