--!optimize 2
--!strict

-- Loop handlers: every bytecode loop runs as a real host loop.
-- Numeric and generic for loops use the host's own for statements (including its next/inext fast paths and
-- generalized iteration); other loops run their body in a local trampoline.
--
-- Body protocol: the body returns Token to continue, nil when the function returned, a member handler when it
-- bounced inside the loop, or anything else when control leaves the loop (break, outer continue, exit).
-- @param Body Handler – first handler of the loop body
-- @param Token any – value the body returns to start the next iteration
-- @param Members { [Handler]: boolean } – handlers the body may bounce to without leaving the loop
-- @param Exit Handler – successor after normal termination
-- @param Chain boolean – whether Exit is chained

local Types = require("../Types")

type Handler = Types.Handler

local pack = table.pack
local move = table.move
local getmetatable = getmetatable
local next = next

local Loops = {}

-- Runs body bounces until the iteration ends; returns Token to continue or the value that leaves the loop.
local function Settle(S: { any }, f: any, Token: any, Members: { [any]: boolean }): any
	while Members[f] do
		f = f(S)
		if f == Token then
			return f
		end
	end
	return f
end

-- FORNPREP/FORNLOOP: runs a host numeric for; the setup operands may be registers or constant slots.
-- @param I number – frame index of the visible loop variable
-- @param Limit number – frame index of the limit
-- @param Step number – frame index of the step
-- @param Start number – frame index of the initial value
function Loops.Numeric(I: number, Limit: number, Step: number, Start: number, Body: Handler, Token: any, Members: { [any]: boolean }, Exit: Handler, Chain: boolean): Handler
	return function(S)
		for i = S[Start], S[Limit], S[Step] do
			S[I] = i
			local f = Body(S)
			if f ~= Token then
				f = Settle(S, f, Token, Members)
				if f ~= Token then
					return f
				end
			end
		end
		if Chain then
			return Exit(S)
		end
		return Exit
	end
end

-- FORGPREP*/FORGLOOP: registers A generator, A+1 state, A+2 control, variables from A+3.
-- @param Count number – loop variable count
function Loops.Generic(A: number, Count: number, Body: Handler, Token: any, Members: { [any]: boolean }, Exit: Handler, Chain: boolean): Handler
	local A1, A2, A3, A4, A5 = A + 1, A + 2, A + 3, A + 4, A + 5
	local function Leave(S: { any }): any
		if Chain then
			return Exit(S)
		end
		return Exit
	end

	if Count == 1 then
		return function(S)
			for a in S[A], S[A1], S[A2] do
				S[A3] = a
				local f = Body(S)
				if f ~= Token then
					f = Settle(S, f, Token, Members)
					if f ~= Token then
						return f
					end
				end
			end
			return Leave(S)
		end
	elseif Count == 2 then
		return function(S)
			for a, b in S[A], S[A1], S[A2] do
				S[A3], S[A4] = a, b
				local f = Body(S)
				if f ~= Token then
					f = Settle(S, f, Token, Members)
					if f ~= Token then
						return f
					end
				end
			end
			return Leave(S)
		end
	elseif Count == 3 then
		return function(S)
			for a, b, c in S[A], S[A1], S[A2] do
				S[A3], S[A4], S[A5] = a, b, c
				local f = Body(S)
				if f ~= Token then
					f = Settle(S, f, Token, Members)
					if f ~= Token then
						return f
					end
				end
			end
			return Leave(S)
		end
	end

	-- wide loops: generalized iteration done by hand (tables iterate like next, __iter is honoured)
	return function(S)
		local gen, state, control = S[A], S[A1], S[A2]
		if type(gen) ~= "function" then
			local mt = getmetatable(gen)
			local iter = if type(mt) == "table" then mt.__iter else nil
			if iter then
				gen, state, control = iter(gen)
			elseif type(gen) == "table" then
				gen, state, control = next, gen, nil
			else
				error(`attempt to iterate over a {typeof(gen)} value`)
			end
		end
		while true do
			local values = pack(gen(state, control))
			control = values[1]
			if control == nil then
				break
			end
			move(values, 1, Count, A3, S)
			local f = Body(S)
			if f ~= Token then
				f = Settle(S, f, Token, Members)
				if f ~= Token then
					return f
				end
			end
		end
		return Leave(S)
	end
end

-- Loops closed by a backward jump (while, repeat, goto-free continue): the body restarts on Token.
function Loops.Back(Body: Handler, Token: any, Members: { [any]: boolean }): Handler
	return function(S)
		local f = Body(S)
		while true do
			if f == Token then
				f = Body(S)
			elseif Members[f] then
				f = f(S)
			else
				return f
			end
		end
	end
end

return Loops
