--!strict

-- Shared type definitions for the interpreter modules.

-- Deserialized function prototype; operands stay raw until the compiler decodes them.
export type Proto = {
	MaxStack: number,
	Params: number,
	Upvalues: number,
	IsVararg: boolean,
	Flags: number,
	Code: { number },
	Constants: { any },
	Imports: { [number]: number }, -- constant index -> encoded import path
	Closures: { [number]: number }, -- constant index -> proto index (DUPCLOSURE)
	Children: { number }, -- child proto indices (NEWCLOSURE)
	Name: string?,
	Lines: { number }?, -- source line per code word, when compiled with line info
}

export type Chunk = {
	Protos: { Proto },
	Main: number,
}

-- Register file of one activation: [1] upvalues, [2] varargs, [3] vararg count / result kind, [4] open cells, [5] top, registers from [6].
export type Frame = { any }

-- A compiled instruction: runs on a frame and returns its successor, a loop token, or nil when the function returned.
export type Handler = (Frame) -> any

-- Builds the host closure for a proto given its upvalue table.
export type Factory = ({ any }) -> (...any) -> ...any

export type Options = {
	Vector: ((number, number, number, number) -> any)?, -- vector constant constructor
	SafeEnv: boolean?, -- resolve imports once at load (default true)
	ChunkName: string?, -- position prefix for errors raised by guest error()/assert() and method calls
	DynamicEnv: (boolean | any)?, -- per-closure environments with getfenv/setfenv; true or a state from NewEnvState
	Debug: boolean?, -- position host-raised errors (arithmetic on nil, calling nil) at the guest line; slower
}

return nil
