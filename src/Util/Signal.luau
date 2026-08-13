--!strict
--[[
	Signal - a fast, pure-Luau event/pub-sub class, independent of
	BindableEvent (no Instance overhead, works identically on server and
	client, and lets you Fire non-serializable values like functions or
	custom tables - BindableEvent can't carry those across its boundary).

	Self-written for Thread (not a copy-pasted dependency), following the
	well-known "GoodSignal" linked-list + pooled-coroutine shape that's
	become the de facto standard for Lua signal classes on Roblox
	(originally popularized by stravant, later adopted by Knit/RbxUtil and
	many other frameworks) - it's the standard shape because it's fast and
	yield-safe, not because it's any one library's invention.

	Useful for service-internal events (server-only or client-only) where
	Channel's Remote-backed Signal would be overkill, or for general-purpose
	same-context pub-sub anywhere in your game.
]]

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
	Destroy: (self: Connection) -> (),
}

export type Signal = {
	Connect: (self: Signal, fn: (...any) -> ()) -> Connection,
	Once: (self: Signal, fn: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	Wait: (self: Signal) -> ...any,
	DisconnectAll: (self: Signal) -> (),
	GetConnections: (self: Signal) -> { Connection },
	Destroy: (self: Signal) -> (),
}

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

local function newConnection(signal: any, fn: (...any) -> ()): any
	return setmetatable({
		Connected = true,
		_signal = signal,
		_fn = fn,
		_next = nil,
	}, Connection)
end

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false

	local signal = self._signal
	if signal._handlerListHead == self then
		signal._handlerListHead = self._next
	else
		local prev = signal._handlerListHead
		while prev and prev._next ~= self do
			prev = prev._next
		end
		if prev then
			prev._next = self._next
		end
	end
end

Connection.Destroy = Connection.Disconnect

--------------------------------------------------
-- Pooled coroutine runner, so Fire() doesn't spawn
-- a brand new coroutine on every single call.
--------------------------------------------------

local freeRunnerThread: thread? = nil

local function runHandler(fn: (...any) -> (), ...: any)
	local acquired = freeRunnerThread
	freeRunnerThread = nil
	fn(...)
	freeRunnerThread = acquired
end

local function runnerLoop(fn: (...any) -> (), ...: any)
	runHandler(fn, ...)
	while true do
		runHandler(coroutine.yield())
	end
end

local function schedule(fn: (...any) -> (), ...: any)
	if not freeRunnerThread then
		freeRunnerThread = coroutine.create(runnerLoop)
	end
	task.spawn(freeRunnerThread :: thread, fn, ...)
end

--------------------------------------------------
-- Signal
--------------------------------------------------

function Signal.new(): Signal
	return (setmetatable({
		_handlerListHead = nil,
		_proxyConnection = nil :: RBXScriptConnection?,
	}, Signal) :: any) :: Signal
end

-- Wraps an existing RBXScriptSignal so it can be used through this same API
-- (handy for mixing engine signals with Thread.Trove/Thread.Signal uniformly).
function Signal.Wrap(rbxScriptSignal: RBXScriptSignal): Signal
	assert(typeof(rbxScriptSignal) == "RBXScriptSignal", "Signal.Wrap expects an RBXScriptSignal")

	local signal = Signal.new() :: any
	signal._proxyConnection = rbxScriptSignal:Connect(function(...)
		signal:Fire(...)
	end)

	return signal
end

function Signal.Is(obj: any): boolean
	return type(obj) == "table" and getmetatable(obj) == Signal
end

function Signal:Connect(fn: (...any) -> ()): Connection
	assert(type(fn) == "function", "Signal:Connect expects a function")

	local connection = newConnection(self, fn)
	if self._handlerListHead then
		connection._next = self._handlerListHead
	end
	self._handlerListHead = connection

	return connection
end

function Signal:Once(fn: (...any) -> ()): Connection
	assert(type(fn) == "function", "Signal:Once expects a function")

	local connection: Connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)

	return connection
end

function Signal:Fire(...: any)
	local item = self._handlerListHead
	while item do
		if item.Connected then
			schedule(item._fn, ...)
		end
		item = item._next
	end
end

function Signal:Wait(): ...any
	local thread = coroutine.running()
	local connection: Connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:GetConnections(): { Connection }
	local out = {}
	local item = self._handlerListHead
	while item do
		table.insert(out, item)
		item = item._next
	end
	return out
end

function Signal:DisconnectAll()
	local item = self._handlerListHead
	while item do
		item.Connected = false
		item = item._next
	end
	self._handlerListHead = nil
end

function Signal:Destroy()
	self:DisconnectAll()
	if self._proxyConnection then
		self._proxyConnection:Disconnect()
		self._proxyConnection = nil
	end
end

return Signal
