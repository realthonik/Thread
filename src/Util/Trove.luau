--!strict
--[[
	Trove - tracks arbitrary "cleanupable" objects (Instances, connections,
	Signals, functions, threads, or any table with a Destroy/Disconnect
	method) so they can all be torn down together with a single call.

	Self-written for Thread, inspired by the well-known Trove/Maid pattern
	used across the Roblox ecosystem (incl. Sleitnick's RbxUtil Trove).
	No external dependency - just plain Luau + task.cancel/Instance:Destroy.

	Example:
		local trove = Trove.new()

		trove:Add(workspace.Baseplate:Clone())
		trove:Connect(player.CharacterAdded, onCharacterAdded)
		trove:Add(function()
			print("extra cleanup")
		end)

		-- later:
		trove:Destroy() -- destroys the clone, disconnects the connection,
		                 -- and calls the function
]]

export type Trackable = Instance | RBXScriptConnection | thread | ((...any) -> ...any) | { [string]: any }

export type SignalLike = {
	Connect: (self: SignalLike, fn: (...any) -> ...any) -> any,
}

local Trove = {}
Trove.__index = Trove

local GENERIC_CLEANUP_METHODS = { "Destroy", "Disconnect", "destroy", "disconnect" }

local function getCleanupMethod(object: any, cleanupMethod: string?): string | "function" | "thread"
	local t = typeof(object)

	if t == "function" then
		return "function"
	elseif t == "thread" then
		return "thread"
	end

	if cleanupMethod then
		assert(type(object[cleanupMethod]) == "function", ("Trove:Add object has no method '%s'"):format(cleanupMethod))
		return cleanupMethod
	end

	if t == "Instance" then
		return "Destroy"
	elseif t == "RBXScriptConnection" then
		return "Disconnect"
	elseif t == "table" then
		for _, method in ipairs(GENERIC_CLEANUP_METHODS) do
			if type(object[method]) == "function" then
				return method
			end
		end
	end

	error(("Trove:Add - could not determine a cleanup method for a %s value"):format(t), 3)
end

function Trove.new()
	return setmetatable({
		_objects = {} :: { { any } },
		_cleaning = false,
	}, Trove)
end

-- Tracks `object`, to be cleaned up when the trove is cleaned/destroyed.
-- Returns `object` unchanged, so this can wrap a constructor call inline.
function Trove:Add(object: Trackable, cleanupMethod: string?): any
	assert(not self._cleaning, "Cannot call Trove:Add while cleaning")

	local method = getCleanupMethod(object, cleanupMethod)
	table.insert(self._objects, { object, method })

	return object
end

-- Removes `object` from the trove WITHOUT cleaning it up. Returns true if it
-- was tracked.
function Trove:Remove(object: any): boolean
	for i, entry in ipairs(self._objects) do
		if entry[1] == object then
			table.remove(self._objects, i)
			return true
		end
	end
	return false
end

-- Shorthand for `trove:Add(signal:Connect(fn))`.
function Trove:Connect(signal: SignalLike | RBXScriptSignal, fn: (...any) -> ...any): any
	return self:Add((signal :: SignalLike):Connect(fn))
end

-- Shorthand for `trove:Add(instance:Clone())`.
function Trove:Clone(instance: Instance): Instance
	return self:Add(instance:Clone())
end

-- Constructs an object via `class.new(...)` (or `class(...)` if `class` is a
-- plain function) and adds the result to the trove. Shorthand for
-- `trove:Add(SomeClass.new(...))`.
function Trove:Construct(class: { new: (...any) -> any } | ((...any) -> any), ...: any): any
	local object
	if type(class) == "table" then
		object = (class :: any).new(...)
	else
		object = (class :: any)(...)
	end
	return self:Add(object)
end

-- Cleans up every tracked object without destroying the trove itself - the
-- trove can keep being used afterward.
function Trove:Clean()
	self._cleaning = true

	for _, entry in ipairs(self._objects) do
		local object, method = entry[1], entry[2]

		if method == "function" then
			task.spawn(object)
		elseif method == "thread" then
			task.cancel(object)
		else
			local ok, err = pcall(function()
				(object :: any)[method](object)
			end)
			if not ok then
				warn("[Trove] Cleanup error:", err)
			end
		end
	end

	table.clear(self._objects)
	self._cleaning = false
end

-- Cleans up every tracked object and marks the trove unusable.
function Trove:Destroy()
	self:Clean()
end

-- Returns a new Trove that will automatically be cleaned up when this trove
-- is cleaned/destroyed - useful for scoping a subset of cleanup (e.g. one
-- Trove per player session, extended from a single service-wide Trove).
function Trove:Extend()
	local subTrove = Trove.new()
	self:Add(subTrove)
	return subTrove
end

-- Cleans up the trove automatically once `instance` is removed from the
-- game (Parent becomes nil / Destroying fires). Returns the connection.
function Trove:AttachToInstance(instance: Instance): RBXScriptConnection
	assert(instance:IsDescendantOf(game), "Trove:AttachToInstance expects an instance currently in the DataModel")
	return self:Connect(instance.Destroying, function()
		self:Destroy()
	end)
end

return Trove
