--!strict
--[[
	Minimal Promise implementation (A+-ish, Roblox-flavoured).
	No external dependencies - self-contained on purpose.
]]

local Promise = {}
Promise.__index = Promise

export type Promise<T = any> = typeof(setmetatable(
	{} :: {
		_state: "Pending" | "Resolved" | "Rejected",
		_value: T,
		_resolveQueue: { (T) -> () },
		_rejectQueue: { (any) -> () },
	},
	Promise
))

local function isPromise(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Promise
end

Promise.is = isPromise

function Promise.new(executor: (resolve: (any) -> (), reject: (any) -> ()) -> ()): Promise
	local self = setmetatable({
		_state = "Pending",
		_value = nil,
		_resolveQueue = {},
		_rejectQueue = {},
	}, Promise)

	local function resolve(value: any)
		if self._state ~= "Pending" then
			return
		end

		if isPromise(value) then
			value:andThen(resolve, function(err)
				if self._state ~= "Pending" then
					return
				end
				self._state = "Rejected"
				self._value = err
				for _, callback in ipairs(self._rejectQueue) do
					task.spawn(callback, err)
				end
			end)
			return
		end

		self._state = "Resolved"
		self._value = value
		for _, callback in ipairs(self._resolveQueue) do
			task.spawn(callback, value)
		end
	end

	local function reject(err: any)
		if self._state ~= "Pending" then
			return
		end
		self._state = "Rejected"
		self._value = err
		for _, callback in ipairs(self._rejectQueue) do
			task.spawn(callback, err)
		end
	end

	task.spawn(function()
		local success, err = pcall(executor, resolve, reject)
		if not success then
			reject(err)
		end
	end)

	return self
end

function Promise.resolve(value: any): Promise
	return Promise.new(function(resolve)
		resolve(value)
	end)
end

function Promise.reject(err: any): Promise
	return Promise.new(function(_, reject)
		reject(err)
	end)
end

function Promise.all(promises: { Promise }): Promise
	return Promise.new(function(resolve, reject)
		local results = {}
		local remaining = #promises

		if remaining == 0 then
			resolve(results)
			return
		end

		for i, promise in ipairs(promises) do
			promise:andThen(function(value)
				results[i] = value
				remaining -= 1
				if remaining == 0 then
					resolve(results)
				end
			end, reject)
		end
	end)
end

--[[
	Like Promise.all, but never rejects - resolves once every promise has
	settled (either resolved or rejected), with a per-entry status report.
	Useful for "start everything, tell me what failed" flows.
]]
function Promise.allSettled(promises: { Promise }): Promise
	return Promise.new(function(resolve)
		local results = {}
		local remaining = #promises

		if remaining == 0 then
			resolve(results)
			return
		end

		for i, promise in ipairs(promises) do
			promise:andThen(function(value)
				results[i] = { Status = "Resolved", Value = value }
				remaining -= 1
				if remaining == 0 then
					resolve(results)
				end
			end, function(err)
				results[i] = { Status = "Rejected", Error = err }
				remaining -= 1
				if remaining == 0 then
					resolve(results)
				end
			end)
		end
	end)
end

-- Settles with whichever promise settles first (resolve OR reject).
function Promise.race(promises: { Promise }): Promise
	return Promise.new(function(resolve, reject)
		if #promises == 0 then
			reject("Promise.race: no promises given")
			return
		end
		for _, promise in ipairs(promises) do
			promise:andThen(resolve, reject)
		end
	end)
end

-- Resolves once `count` of the given promises have resolved, with an array
-- of their values (in completion order). Rejects as soon as reaching
-- `count` resolutions becomes impossible (too many have already rejected).
function Promise.some(promises: { Promise }, count: number): Promise
	return Promise.new(function(resolve, reject)
		assert(count > 0, "Promise.some: count must be > 0")

		local total = #promises
		if count > total then
			reject(("Promise.some: requested %d results from only %d promises"):format(count, total))
			return
		end

		local results = {}
		local resolvedCount = 0
		local rejectedCount = 0
		local settled = false

		for _, promise in ipairs(promises) do
			promise:andThen(function(value)
				if settled then
					return
				end
				resolvedCount += 1
				table.insert(results, value)
				if resolvedCount >= count then
					settled = true
					resolve(results)
				end
			end, function(err)
				if settled then
					return
				end
				rejectedCount += 1
				if total - rejectedCount < count then
					settled = true
					reject(("Promise.some: too many rejections, last error: %s"):format(tostring(err)))
				end
			end)
		end
	end)
end

-- Resolves with no value after `seconds`. Handy for chains, e.g.
-- `Promise.delay(1):andThen(function() ... end)`.
function Promise.delay(seconds: number): Promise
	return Promise.new(function(resolve)
		task.delay(seconds, resolve)
	end)
end

-- Calls `fn()` (which must return a Promise) up to `attempts` times,
-- resolving on the first success and rejecting with the last error if
-- every attempt fails.
function Promise.retry(fn: () -> Promise, attempts: number): Promise
	assert(type(fn) == "function", "Promise.retry: fn must be a function")
	assert(attempts > 0, "Promise.retry: attempts must be > 0")

	return Promise.new(function(resolve, reject)
		local function attempt(n: number)
			fn():andThen(resolve, function(err)
				if n >= attempts then
					reject(err)
				else
					attempt(n + 1)
				end
			end)
		end
		attempt(1)
	end)
end

-- Wraps an RBXScriptSignal (or anything duck-typed like one, e.g. Thread's
-- own Signal module) into a Promise that resolves the next time it fires.
-- If the event fires with more than one argument, they're packed into an
-- array; with 0 or 1 argument, resolves with that value directly.
export type EventLike = { Connect: (self: any, fn: (...any) -> ()) -> { Disconnect: (self: any) -> () } }

function Promise.fromEvent(event: RBXScriptSignal | EventLike, predicate: ((...any) -> boolean)?): Promise
	return Promise.new(function(resolve)
		local connection
		connection = event:Connect(function(...)
			if predicate and not predicate(...) then
				return
			end
			if connection then
				connection:Disconnect()
			end
			local n = select("#", ...)
			if n <= 1 then
				resolve(...)
			else
				resolve({ ... })
			end
		end)
	end)
end

function Promise:andThen(onResolve: ((any) -> any)?, onReject: ((any) -> any)?): Promise
	return Promise.new(function(resolve, reject)
		local function handleResolve(value: any)
			if type(onResolve) ~= "function" then
				resolve(value)
				return
			end
			local success, result = pcall(onResolve, value)
			if success then
				resolve(result)
			else
				reject(result)
			end
		end

		local function handleReject(err: any)
			if type(onReject) ~= "function" then
				reject(err)
				return
			end
			local success, result = pcall(onReject, err)
			if success then
				resolve(result)
			else
				reject(result)
			end
		end

		if self._state == "Resolved" then
			task.spawn(handleResolve, self._value)
		elseif self._state == "Rejected" then
			task.spawn(handleReject, self._value)
		else
			table.insert(self._resolveQueue, handleResolve)
			table.insert(self._rejectQueue, handleReject)
		end
	end)
end

function Promise:catch(onReject: (any) -> any): Promise
	return self:andThen(nil, onReject)
end

function Promise:finally(callback: () -> ()): Promise
	return self:andThen(function(value)
		callback()
		return value
	end, function(err)
		callback()
		error(err, 0)
	end)
end

-- Rejects if this promise hasn't settled within `seconds`. Does not cancel
-- whatever work the original promise represents - it just stops waiting.
function Promise:timeout(seconds: number, timeoutError: any?): Promise
	return Promise.race({
		self,
		Promise.delay(seconds):andThen(function()
			error(timeoutError or ("Promise timed out after %ds"):format(seconds), 0)
		end),
	})
end

function Promise:await(): any
	if self._state == "Resolved" then
		return self._value
	end
	if self._state == "Rejected" then
		error(self._value, 0)
	end

	local thread = coroutine.running()
	table.insert(self._resolveQueue, function(value)
		task.spawn(thread, true, value)
	end)
	table.insert(self._rejectQueue, function(err)
		task.spawn(thread, false, err)
	end)

	local success, result = coroutine.yield()
	if not success then
		error(result, 0)
	end
	return result
end

function Promise:getState(): string
	return self._state
end

return Promise
