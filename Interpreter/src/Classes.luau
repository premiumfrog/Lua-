--!optimize 2
--!strict

-- Luau classes (bytecode versions 10 and 100): class objects, instances and the `class` library, after VM/src/lclass.cpp.
-- Why: class bytecode needs a runtime object model; pure Luau cannot create new value types, so classes and
-- instances are tables whose shared metatables reproduce the host's member rules and error messages, and the
-- builtins that reveal a type (type, typeof, getmetatable) are swapped for class-aware versions in class chunks.
--
-- A class record mirrors LuauClass: member offsets are 0-based, instance members come first (public fields, then
-- private fields), then static members (public methods, then private methods). An instance stores its members by
-- offset + 1 in an array held under a private key, so every named access goes through the class's metamethods.

export type Class = {
	Name: string,
	Id: number,
	IsOpen: boolean,
	Super: Class?,
	Members: { [any]: number }, -- public member name -> offset
	Names: { [number]: string }, -- offset -> name; private fields and private methods have none
	NInstance: number,
	NMembers: number,
	NPrivateFields: number,
	OwnPrivateStart: number,
	NPrivateStatics: number,
	Statics: { any }, -- static offset + 1 -> value; private methods occupy the last NPrivateStatics slots
	HasUserInit: boolean,
	InstanceMeta: { [string]: any }?, -- user metamethods, inherited by subclasses
	ObjectMeta: { [any]: any }, -- metatable of instances
	Proxy: { [any]: any }, -- the guest-visible class value
}

-- Private keys: an instance's member array and a class value's record
local STORE, CLASS = newproxy(false), newproxy(false)

local hostType, hostTypeof, hostGetmetatable = type, typeof, getmetatable
local create = table.create
local format = string.format

local lastId = 0
local addresses = 0

local Classes = {}

-- Fake address for default tostring; real addresses are not observable from Luau.
local function Address(kind: string): string
	addresses += 1
	return format("%s: 0x%016x", kind, addresses)
end

-- Guest-visible type name, as luaT_objtypename reports it.
local function TypeName(value: any): string
	if hostType(value) == "table" then
		if rawget(value, STORE) ~= nil then
			return "object"
		elseif rawget(value, CLASS) ~= nil then
			return "class"
		end
	end
	return hostTypeof(value)
end

-- Raises a host runtime error (luaG_runerror). The position names this module, which the Debug option replaces
-- with the guest instruction's, as it does for every error raised inside the interpreter.
local function Raise(message: string): never
	error(message, 1)
end

local function MissingMember(object: any, key: any): never
	if hostType(key) ~= "string" then
		Raise(`cannot index {TypeName(object)} with a {TypeName(key)}`)
	end
	Raise(`this {TypeName(object)} does not have a key named '{key}'`)
end

local function IndexError(object: any, key: any): never
	if hostType(key) == "string" and #key <= 64 then
		Raise(`attempt to index {TypeName(object)} with '{key}'`)
	end
	Raise(`attempt to index {TypeName(object)} with {TypeName(key)}`)
end

-- Metamethods every instance and class value has unless the class defines its own: they raise the host's
-- errors for a value without metamethods, named "object"/"class" instead of "table".
local ARITH = { "add", "sub", "mul", "div", "mod", "pow", "idiv" }

local function Defaults(meta: { [any]: any })
	for _, op in ARITH do
		meta["__" .. op] = function(a, b)
			local ta, tb = TypeName(a), TypeName(b)
			if ta == tb then
				Raise(`attempt to perform arithmetic ({op}) on {ta}`)
			end
			Raise(`attempt to perform arithmetic ({op}) on {ta} and {tb}`)
		end
	end
	meta.__unm = function(a)
		Raise(`attempt to perform arithmetic (unm) on {TypeName(a)}`)
	end
	meta.__lt = function(a, b)
		Raise(`attempt to compare {TypeName(a)} < {TypeName(b)}`)
	end
	meta.__le = function(a, b)
		Raise(`attempt to compare {TypeName(a)} <= {TypeName(b)}`)
	end
	meta.__concat = function(a, b)
		Raise(`attempt to concatenate {TypeName(a)} with {TypeName(b)}`)
	end
	meta.__len = function(a)
		Raise(`attempt to get length of a {TypeName(a)} value`)
	end
	meta.__call = function(a)
		Raise(`attempt to call a {TypeName(a)} value`)
	end
	meta.__iter = function(a)
		Raise(`attempt to iterate over a {TypeName(a)} value`)
	end
	meta.__metatable = false
end

-- Class value metatable, shared by every class: static members, construction and the host's errors.
local ClassMeta: { [any]: any } = {}
Defaults(ClassMeta)

ClassMeta.__index = function(proxy, key)
	local cls: Class = rawget(proxy, CLASS)
	local offset = cls.Members[key]
	if offset == nil or offset < cls.NInstance then
		MissingMember(proxy, key)
	end
	return cls.Statics[offset - cls.NInstance + 1]
end

ClassMeta.__newindex = function(proxy, key)
	IndexError(proxy, key)
end

ClassMeta.__tostring = function(proxy)
	local cls: Class = rawget(proxy, CLASS)
	local text = (cls :: any).Text
	if not text then
		text = Address("class")
		;(cls :: any).Text = text
	end
	return text
end

-- luaR_constructobject: the class value's __call. Creates a blank instance and runs __init on it.
ClassMeta.__call = function(proxy, ...)
	local cls: Class = rawget(proxy, CLASS)
	local self = Classes.Blank(cls)
	local init = cls.Statics[cls.Members.__init - cls.NInstance + 1]
	init(self, ...)
	return self
end

-- Instance metatable of a class: member access by offset; user metamethods are added as they are registered.
local function ObjectMeta(cls: Class): { [any]: any }
	local meta: { [any]: any } = {}
	Defaults(meta)
	local members = cls.Members
	local count = cls.NInstance
	meta.__index = function(object, key)
		local offset = members[key]
		if offset == nil then
			MissingMember(object, key)
		elseif offset < count then
			return rawget(object, STORE)[offset + 1]
		end
		return cls.Statics[offset - count + 1]
	end
	meta.__newindex = function(object, key, value)
		local offset = members[key]
		if offset == nil then
			MissingMember(object, key)
		elseif offset >= count then
			IndexError(object, key)
		end
		rawget(object, STORE)[offset + 1] = value
	end
	meta.__tostring = function(object)
		local store = rawget(object, STORE)
		local text = store.Text
		if not text then
			text = Address("object")
			store.Text = text
		end
		return text
	end
	return meta
end

-- Makes the guest-visible value for a class record.
local function Publish(cls: Class): { [any]: any }
	local proxy = setmetatable({ [CLASS] = cls }, ClassMeta)
	cls.Proxy = proxy
	return proxy
end

local function NewBlankClass(name: string, isOpen: boolean): Class
	lastId += 1
	return {
		Name = name,
		Id = lastId,
		IsOpen = isOpen,
		Super = nil,
		Members = {},
		Names = {},
		NInstance = 0,
		NMembers = 0,
		NPrivateFields = 0,
		OwnPrivateStart = 0,
		NPrivateStatics = 0,
		Statics = {},
		HasUserInit = false,
		InstanceMeta = nil,
		ObjectMeta = nil :: any,
		Proxy = nil :: any,
	}
end

-- luaR_defaultcreateobject: the __init every class starts with; copies fields from a property table.
local function DefaultInit(cls: Class): (...any) -> ()
	return function(...)
		if cls.HasUserInit then
			error(`Class {cls.Name} must define a constructor because it is derived from a class that defines one`, 0)
		elseif cls.NPrivateFields ~= 0 then
			if cls.Super then
				error(`Class {cls.Name} must define a constructor because it or a class it inherits from has private fields`, 0)
			end
			error(`Class {cls.Name} must define a constructor because it has private fields`, 0)
		end
		local count = select("#", ...)
		if count ~= 2 then
			error(`The constructor of {cls.Name} must be called with 2 arguments.  Got {count}`, 0)
		end
		local self, props = ...
		local store = if hostType(self) == "table" then rawget(self, STORE) else nil
		if store == nil then
			error(`{cls.Name}.__init must be called with an instance of the class as its first argument`, 0)
		end
		local owner: Class = store[0]
		if owner ~= cls then
			error(`Cannot call {cls.Name}.__init on an instance of class {owner.Name}`, 0)
		end
		local names = cls.Names
		for offset = 0, cls.NInstance - 1 do
			local name = names[offset]
			if name ~= nil then
				store[offset + 1] = props[name]
			end
		end
	end
end

-- luaR_setupconstructor: installs the default __init in the class's __init slot.
local function SetupConstructor(cls: Class)
	cls.ObjectMeta = cls.ObjectMeta or ObjectMeta(cls)
	local offset = cls.Members.__init
	assert(offset ~= nil and offset >= cls.NInstance, "class shape has no __init")
	cls.Statics[offset - cls.NInstance + 1] = DefaultInit(cls)
end

-- luaR_newclass: a class from its LBC_CONSTANT_CLASS_SHAPE constant, as the loader builds it.
-- @param publicFields { string } – public instance field names in offset order
-- @param publicMethods { string } – public method names in offset order (after every instance member)
-- @param privateFields number – unnamed instance fields after the public ones
-- @param privateMethods number – unnamed methods after the public ones
function Classes.FromShape(name: string, publicFields: { string }, publicMethods: { string }, privateFields: number, privateMethods: number): any
	local cls = NewBlankClass(name, false)
	local nInstance = #publicFields + privateFields
	local nStatic = #publicMethods + privateMethods
	for i, field in publicFields do
		cls.Members[field] = i - 1
		cls.Names[i - 1] = field
	end
	for i, method in publicMethods do
		cls.Members[method] = nInstance + i - 1
		cls.Names[nInstance + i - 1] = method
	end
	cls.NInstance = nInstance
	cls.NMembers = nInstance + nStatic
	cls.NPrivateFields = privateFields
	cls.OwnPrivateStart = nInstance - privateFields
	cls.NPrivateStatics = privateMethods
	cls.Statics = create(nStatic)
	SetupConstructor(cls)
	return Publish(cls)
end

-- Class record of a class value, or nil.
function Classes.Of(value: any): Class?
	if hostType(value) == "table" then
		return rawget(value, CLASS)
	end
	return nil
end

-- Member array of an instance, or nil.
function Classes.StoreOf(value: any): { any }?
	if hostType(value) == "table" then
		return rawget(value, STORE)
	end
	return nil
end

-- luaR_newblankobject with members set to nil.
function Classes.Blank(cls: Class): any
	local store = create(cls.NInstance)
	store[0] = cls
	return setmetatable({ [STORE] = store }, cls.ObjectMeta)
end

-- Sets the instance metatable entry for a metamethod, keeping the defaults for the rest.
local function SetMetamethod(cls: Class, name: string, value: any)
	local user = cls.InstanceMeta
	if not user then
		user = {}
		cls.InstanceMeta = user
	end
	user[name] = value
	cls.ObjectMeta[name] = value
end

-- Names the host treats as metamethods for classes (the parser's allowlist; __init is a plain static).
local METAMETHODS = {
	__call = true, __concat = true, __unm = true, __add = true, __sub = true, __mul = true, __div = true,
	__mod = true, __pow = true, __tostring = true, __eq = true, __lt = true, __le = true, __iter = true,
	__len = true, __idiv = true,
}

-- luaR_addpublicstaticmember (NEWCLASSMEMBER, public).
function Classes.AddPublic(proxy: any, name: string, value: any)
	local cls = rawget(proxy, CLASS) :: Class
	local offset = cls.Members[name]
	cls.Statics[offset - cls.NInstance + 1] = value
	if name == "__init" then
		cls.HasUserInit = true
	end
	if METAMETHODS[name] then
		local user = cls.InstanceMeta
		if user and (name == "__eq" or name == "__lt" or name == "__le") and user[name] ~= nil then
			Raise(`Overriding comparison metamethods is not allowed ('{name}' in class '{cls.Name}')`)
		end
		SetMetamethod(cls, name, value)
	end
end

-- luaR_addprivatestaticmember (NEWCLASSMEMBER, private).
function Classes.AddPrivate(proxy: any, index: number, value: any)
	local cls = rawget(proxy, CLASS) :: Class
	cls.Statics[cls.NMembers - cls.NInstance - cls.NPrivateStatics + index + 1] = value
end

-- luaR_inheritclass: a flattened class combining parent and child, as NEWCLASS with a superclass makes.
function Classes.Inherit(childProxy: any, parentProxy: any): any
	local child = rawget(childProxy, CLASS) :: Class
	local parent = rawget(parentProxy, CLASS) :: Class
	if not parent.IsOpen then
		Raise(`Non-open class '{parent.Name}' cannot be extended`)
	end
	for offset = 0, parent.NInstance - 1 do
		local name = parent.Names[offset]
		if name ~= nil and child.Members[name] ~= nil then
			Raise(`Cannot override instance member '{name}' of parent class '{parent.Name}' in child class '{child.Name}'`)
		end
	end

	local cls = NewBlankClass(child.Name, child.IsOpen)
	cls.Super = parent
	cls.HasUserInit = parent.HasUserInit

	local offset = 0
	for i = 0, parent.NInstance - 1 do
		local name = parent.Names[i]
		cls.Names[offset] = name
		if name ~= nil then
			cls.Members[name] = offset
		end
		offset += 1
	end
	for i = 0, child.NInstance - 1 do
		local name = child.Names[i]
		cls.Names[offset] = name
		if name ~= nil then
			cls.Members[name] = offset
		end
		offset += 1
	end
	cls.NPrivateFields = child.NPrivateFields + parent.NPrivateFields
	cls.OwnPrivateStart = child.OwnPrivateStart + parent.NInstance
	cls.NInstance = offset

	-- parent's public statics the child does not redeclare, then the child's public statics, then its private ones
	local statics = {}
	local parentPublicEnd = parent.NMembers - parent.NPrivateStatics
	for i = parent.NInstance, parentPublicEnd - 1 do
		local name = parent.Names[i]
		if child.Members[name] == nil then
			table.insert(statics, name)
			cls.Statics[#statics] = parent.Statics[i - parent.NInstance + 1]
		end
	end
	local childPublicEnd = child.NMembers - child.NPrivateStatics
	for i = child.NInstance, childPublicEnd - 1 do
		local name = child.Names[i]
		table.insert(statics, name)
		cls.Statics[#statics] = child.Statics[i - child.NInstance + 1]
	end
	for i, name in statics do
		cls.Names[offset + i - 1] = name
		cls.Members[name] = offset + i - 1
	end
	local publicStatics = #statics
	local childPrivateBase = child.NMembers - child.NInstance - child.NPrivateStatics
	for i = 1, child.NPrivateStatics do
		cls.Statics[publicStatics + i] = child.Statics[childPrivateBase + i]
	end
	cls.NPrivateStatics = child.NPrivateStatics
	cls.NMembers = offset + publicStatics + child.NPrivateStatics

	cls.ObjectMeta = ObjectMeta(cls)
	if parent.InstanceMeta then
		for name, value in parent.InstanceMeta do
			SetMetamethod(cls, name, value)
		end
	end
	SetupConstructor(cls)
	return Publish(cls)
end

-- Whether an instance's class is cls or derives from it (luaR_isinstance).
function Classes.IsInstance(store: { any }, cls: Class): boolean
	local c: Class? = store[0]
	while c do
		if c == cls then
			return true
		end
		c = c.Super
	end
	return false
end

-- Whether child is ancestor or derives from it (luaR_issubclass).
function Classes.IsSubclass(child: Class, ancestor: Class): boolean
	local c: Class? = child
	while c do
		if c == ancestor then
			return true
		end
		c = c.Super
	end
	return false
end

-- Private static member of a class by index.
function Classes.PrivateStatic(cls: Class, index: number): any
	return cls.Statics[cls.NMembers - cls.NInstance - cls.NPrivateStatics + index + 1]
end

Classes.TypeName = TypeName

-- The `class` library (lclasslib.cpp).
local function MissingArgument(n: number, fname: string): never
	error(`missing argument #{n} to '{fname}'`, 0)
end

Classes.Library = table.freeze({
	isinstance = function(...)
		local count = select("#", ...)
		local object, cls = ...
		if count < 1 then
			MissingArgument(1, "isinstance")
		end
		local record = Classes.Of(cls)
		if record == nil then
			if count < 2 then
				MissingArgument(2, "isinstance")
			end
			error(`invalid argument #2 to 'isinstance' (class expected, got {TypeName(cls)})`, 0)
		end
		local store = Classes.StoreOf(object)
		return store ~= nil and Classes.IsInstance(store, record :: Class)
	end,
	classof = function(...)
		if select("#", ...) < 1 then
			MissingArgument(1, "classof")
		end
		local store = Classes.StoreOf((...))
		if store == nil then
			return nil
		end
		return (store[0] :: Class).Proxy
	end,
})

-- Class-aware builtins, swapped in for the host's when class bytecode reads them.
Classes.Builtins = {
	type = function(...)
		local value = ...
		if select("#", ...) > 0 and hostType(value) == "table" then
			local name = TypeName(value)
			if name ~= "table" then
				return name
			end
		end
		return hostType(...)
	end,
	typeof = function(...)
		local value = ...
		if select("#", ...) > 0 and hostType(value) == "table" then
			return TypeName(value)
		end
		return hostTypeof(...)
	end,
	getmetatable = function(...)
		local value = ...
		if hostType(value) == "table" and (rawget(value, STORE) ~= nil or rawget(value, CLASS) ~= nil) then
			return nil
		end
		return hostGetmetatable(...)
	end,
}

-- Host builtin -> class-aware replacement.
Classes.Swaps = {
	[hostType] = Classes.Builtins.type,
	[hostTypeof] = Classes.Builtins.typeof,
	[hostGetmetatable] = Classes.Builtins.getmetatable,
} :: { [any]: any }

return Classes
