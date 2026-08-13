--!strict
--[[
	Option - a Rust-inspired Option<T> for explicit "this might not have a
	value" handling, instead of silently passing `nil` around (which Lua
	will happily let you index, compare, or forget to check).

	Self-written for Thread, no external dependency.

	local result = Option.Wrap(dataStore:GetAsync(key))

	result:Match({
		Some = function(value) print("Got:", value) end,
		None = function() print("No value stored") end,
	})
]]

export type MatchTable<T> = {
	Some: (value: T) -> any,
	None: () -> any,
}

export type Option<T> = {
	IsSome: (self: Option<T>) -> boolean,
	IsNone: (self: Option<T>) -> boolean,
	Contains: (self: Option<T>, value: T) -> boolean,
	Match: (self: Option<T>, matches: MatchTable<T>) -> any,
	Unwrap: (self: Option<T>) -> T,
	Expect: (self: Option<T>, errMsg: string) -> T,
	UnwrapOr: (self: Option<T>, default: T) -> T,
	UnwrapOrElse: (self: Option<T>, defaultFn: () -> T) -> T,
	And: (self: Option<T>, other: Option<T>) -> Option<T>,
	AndThen: (self: Option<T>, fn: (value: T) -> Option<T>) -> Option<T>,
	Or: (self: Option<T>, other: Option<T>) -> Option<T>,
	OrElse: (self: Option<T>, fn: () -> Option<T>) -> Option<T>,
}

local CLASS_NAME = "Option"

local Option = {}
Option.__index = Option

local function new(value: any): any
	return setmetatable({
		ClassName = CLASS_NAME,
		_value = value,
		_isSome = value ~= nil,
	}, Option)
end

-- Errors if `value` is nil - use this when you already know the value is
-- present and just want the Option wrapper (e.g. for chaining And/OrElse).
function Option.Some<T>(value: T): Option<T>
	assert(value ~= nil, "Option.Some() value cannot be nil")
	return new(value)
end

-- Safe constructor: returns Option.None if `value` is nil, Option.Some(value)
-- otherwise. This is the one you want most of the time.
function Option.Wrap<T>(value: T?): Option<T>
	if value == nil then
		return (Option.None :: any) :: Option<T>
	end
	return new(value)
end

function Option.Is(obj: any): boolean
	return type(obj) == "table" and getmetatable(obj) == Option
end

function Option:IsSome(): boolean
	return self._isSome
end

function Option:IsNone(): boolean
	return not self._isSome
end

function Option:Contains(value: any): boolean
	return self._isSome and self._value == value
end

function Option:Match(matches: MatchTable<any>): any
	assert(type(matches.Some) == "function", "Option:Match missing 'Some' handler")
	assert(type(matches.None) == "function", "Option:Match missing 'None' handler")

	if self._isSome then
		return matches.Some(self._value)
	end
	return matches.None()
end

function Option:Unwrap(): any
	assert(self._isSome, "Called Unwrap() on an Option.None value")
	return self._value
end

function Option:Expect(errMsg: string): any
	assert(self._isSome, errMsg)
	return self._value
end

function Option:UnwrapOr(default: any): any
	if self._isSome then
		return self._value
	end
	return default
end

function Option:UnwrapOrElse(defaultFn: () -> any): any
	if self._isSome then
		return self._value
	end
	return defaultFn()
end

function Option:And(other: any): any
	if self._isSome then
		return other
	end
	return Option.None
end

function Option:AndThen(fn: (value: any) -> any): any
	if self._isSome then
		return fn(self._value)
	end
	return Option.None
end

function Option:Or(other: any): any
	if self._isSome then
		return self
	end
	return other
end

function Option:OrElse(fn: () -> any): any
	if self._isSome then
		return self
	end
	return fn()
end

-- The single shared "no value" instance. Comparable with `==`.
Option.None = new(nil)

return Option
