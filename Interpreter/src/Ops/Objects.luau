--!optimize 2
--!strict

-- Class instruction handlers: NEWCLASS, NEWCLASSMEMBER, CONSTRUCT, GETPRIVATEFIELD, SETPRIVATEFIELD.
-- The object model itself lives in Classes; errors are raised here so the Debug option positions them at the guest
-- instruction, as the host raises them from its interpreter loop.

local Types = require("../Types")
local Classes = require("../Classes")

type Handler = Types.Handler

local Of, StoreOf, TypeName = Classes.Of, Classes.StoreOf, Classes.TypeName
local IsInstance, IsSubclass, PrivateStatic = Classes.IsInstance, Classes.IsSubclass, Classes.PrivateStatic

local Objects = {}

-- Reads an upvalue holding a class: by value, or through a shared cell.
local function Upvalue(S: { any }, U: number, Boxed: boolean): any
	local value = S[1][U]
	if Boxed then
		return value[1][value[2]]
	end
	return value
end

-- NEWCLASS: hands out the loaded class value; with a superclass, a flattened class derived from both.
-- @param Proxy any – class value built by the loader from its shape constant
-- @param Super number? – frame index of the superclass, or nil
-- @param Open boolean – whether the class may be extended
function Objects.NewClass(A: number, Proxy: any, Super: number?, Open: boolean, Next: Handler, Chain: boolean): Handler
	local record = Of(Proxy) :: Classes.Class
	return function(S)
		S[A] = Proxy
		record.IsOpen = Open
		if Super then
			local parent = S[Super]
			if Of(parent) == nil then
				error(`attempt to extend a {TypeName(parent)} value`)
			end
			S[A] = Classes.Inherit(Proxy, parent)
		end
		return if Chain then Next(S) else Next
	end
end

-- NEWCLASSMEMBER: registers a method (or metamethod) on the class in A.
-- @param Name string? – public member name, or nil for a private method
-- @param Index number – private method index
-- @param C number – frame index of the value
function Objects.NewMember(A: number, Name: string?, Index: number, C: number, Next: Handler, Chain: boolean): Handler
	if Name then
		return function(S)
			Classes.AddPublic(S[A], Name, S[C])
			return if Chain then Next(S) else Next
		end
	end
	return function(S)
		Classes.AddPrivate(S[A], Index, S[C])
		return if Chain then Next(S) else Next
	end
end

-- GETPRIVATEFIELD: a private field of an instance, or a private method of an instance or class.
-- @param U number – upvalue index (1-based) holding the declaring class
-- @param Boxed boolean – whether that upvalue is a shared cell
-- @param Index number – private field offset within the declaring class, or private method index
-- @param Static boolean – whether Index names a private method
-- @param Namecall boolean – also store the object in A + 1, for a method call
function Objects.GetPrivate(A: number, B: number, U: number, Boxed: boolean, Index: number, Static: boolean, Namecall: boolean, Next: Handler, Chain: boolean): Handler
	return function(S)
		local value = S[B]
		local store = StoreOf(value)
		local owner = if store == nil then Of(value) else nil
		if store == nil and owner == nil then
			error(`attempt to access private field of a {TypeName(value)} value`)
		end
		local clsv = Upvalue(S, U, Boxed)
		local cls = Of(clsv)
		if cls == nil then
			error(`attempt to verify object is an instance of a {TypeName(clsv)} value`)
		end
		local result
		if store then
			if not IsInstance(store, cls) then
				error("attempt to illegally access private field")
			end
			result = if Static then PrivateStatic(cls, Index) else store[Index + cls.OwnPrivateStart + 1]
		else
			if not IsSubclass(owner :: Classes.Class, cls) then
				error("attempt to illegally access private field of a class")
			elseif not Static then
				error("attempt to access private instance field of a class")
			end
			result = PrivateStatic(cls, Index)
		end
		if Namecall then
			S[A + 1] = value
		end
		S[A] = result
		return if Chain then Next(S) else Next
	end
end

-- SETPRIVATEFIELD: assigns a private field of an instance of the declaring class (or a subclass).
function Objects.SetPrivate(A: number, B: number, U: number, Boxed: boolean, Index: number, Next: Handler, Chain: boolean): Handler
	return function(S)
		local value = S[B]
		local store = StoreOf(value)
		if store == nil then
			error(`attempt to assign private field of a {TypeName(value)} value`)
		end
		local clsv = Upvalue(S, U, Boxed)
		local cls = Of(clsv)
		if cls == nil then
			error(`attempt to assign private field of a {TypeName(clsv)} value`)
		end
		if not IsInstance(store, cls) then
			error("attempt to assign private field of an object with a different class")
		end
		store[Index + cls.OwnPrivateStart + 1] = S[A]
		return if Chain then Next(S) else Next
	end
end

return Objects
