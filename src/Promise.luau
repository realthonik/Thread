--!strict
--[[
	Small, dependency-free Promise implementation for Roblox.
	Executors receive resolve, reject, and onCancel. Existing two-argument
	executors remain compatible because the third argument is optional to use.
]]

local Promise = {}
Promise.__index = Promise

local CancellationError = {}
CancellationError.__index = CancellationError

function CancellationError:__tostring(): string
	return self.message
end

export type CancellationError = typeof(setmetatable({
	kind = "PromiseCancellation",
	message = "Promise cancelled",
	reason = nil :: any,
}, CancellationError))

export type Promise<T = any> = typeof(setmetatable(
	{} :: {
		_state: "Pending" | "Resolved" | "Rejected" | "Cancelled",
		_value: T,
		_resolveQueue: { (T) -> () },
		_rejectQueue: { (any) -> () },
		_cancelHooks: { () -> () },
		_handled: boolean,
		_rejectInternal: (any) -> (),
		_adopted: any?,
	},
	Promise
))

local function isPromise(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Promise
end

local function isCancelledError(value: any): boolean
	return type(value) == "table" and getmetatable(value) == CancellationError
end

local function makeCancellationError(reason: any?): CancellationError
	return setmetatable({
		kind = "PromiseCancellation",
		message = if reason == nil then "Promise cancelled" else "Promise cancelled: " .. tostring(reason),
		reason = reason,
	}, CancellationError) :: any
end

Promise.is = isPromise
Promise.isCancelledError = isCancelledError

local UnhandledRejectionHandler = function(err: any)
	warn("[Promise] Unhandled rejection:", err)
end

function Promise.setUnhandledRejectionHandler(handler: ((any) -> ())?)
	assert(
		handler == nil or type(handler) == "function",
		"Promise.setUnhandledRejectionHandler expects a function or nil"
	)
	UnhandledRejectionHandler = handler or function(err: any)
		warn("[Promise] Unhandled rejection:", err)
	end
end

function Promise.new(
	executor: (resolve: (any) -> (), reject: (any) -> (), onCancel: (() -> ()) -> boolean) -> ()
): Promise
	assert(type(executor) == "function", "Promise.new expects an executor function")

	local self = setmetatable({
		_state = "Pending",
		_value = nil,
		_resolveQueue = {},
		_rejectQueue = {},
		_cancelHooks = {},
		_handled = false,
		_rejectInternal = function() end,
		_adopted = nil,
	}, Promise)
	local settlementLocked = false

	local function settleRejected(err: any, cancelled: boolean)
		if self._state ~= "Pending" then
			return
		end
		self._state = if cancelled then "Cancelled" else "Rejected"
		self._value = err
		local callbacks = self._rejectQueue
		self._resolveQueue = {}
		self._rejectQueue = {}
		self._cancelHooks = {}
		self._adopted = nil
		for _, callback in ipairs(callbacks) do
			task.spawn(callback, err)
		end
		if not cancelled then
			task.defer(function()
				if self._state == "Rejected" and not self._handled then
					local ok, handlerError = pcall(UnhandledRejectionHandler, self._value)
					if not ok then
						warn("[Promise] Unhandled rejection handler failed:", handlerError)
					end
				end
			end)
		end
	end

	local function settleResolved(value: any)
		if self._state ~= "Pending" then
			return
		end
		self._state = "Resolved"
		self._value = value
		local callbacks = self._resolveQueue
		self._resolveQueue = {}
		self._rejectQueue = {}
		self._cancelHooks = {}
		self._adopted = nil
		for _, callback in ipairs(callbacks) do
			task.spawn(callback, value)
		end
	end

	local function reject(err: any)
		if self._state ~= "Pending" or settlementLocked then
			return
		end
		settlementLocked = true
		settleRejected(err, isCancelledError(err))
	end

	local function resolve(value: any)
		if self._state ~= "Pending" or settlementLocked then
			return
		end
		settlementLocked = true
		if value == self then
			settleRejected("Promise cannot resolve with itself", false)
			return
		end
		if isPromise(value) then
			self._adopted = value
			value:andThen(settleResolved, function(err)
				settleRejected(err, isCancelledError(err))
			end)
			return
		end
		settleResolved(value)
	end

	local function onCancel(callback: () -> ()): boolean
		assert(type(callback) == "function", "Promise onCancel expects a function")
		if self._state == "Cancelled" then
			task.spawn(callback)
			return true
		end
		if self._state ~= "Pending" then
			return false
		end
		table.insert(self._cancelHooks, callback)
		return false
	end

	self._rejectInternal = function(err: any)
		settlementLocked = true
		settleRejected(err, isCancelledError(err))
	end
	local success, err = pcall(executor, resolve, reject, onCancel)
	if not success then
		reject(err)
	end
	return self
end

function Promise.resolve(value: any): Promise
	if isPromise(value) then
		return value
	end
	return Promise.new(function(resolve)
		resolve(value)
	end)
end

function Promise.reject(err: any): Promise
	return Promise.new(function(_, reject)
		reject(err)
	end)
end

function Promise.cancelled(reason: any?): Promise
	return Promise.new(function(_, reject)
		reject(makeCancellationError(reason))
	end)
end

local function cancelAll(promises: { any })
	for _, promise in ipairs(promises) do
		if isPromise(promise) and promise:getState() == "Pending" then
			promise:cancel("parent promise cancelled")
		end
	end
end

function Promise.all(promises: { any }): Promise
	return Promise.new(function(resolve, reject, onCancel)
		local results: { [any]: any } = { n = #promises }
		local remaining = #promises
		onCancel(function()
			cancelAll(promises)
		end)
		if remaining == 0 then
			resolve(results)
			return
		end
		for i, promise in ipairs(promises) do
			Promise.resolve(promise):andThen(function(value)
				results[i] = value
				remaining -= 1
				if remaining == 0 then
					resolve(results)
				end
			end, reject)
		end
	end)
end

function Promise.allSettled(promises: { any }): Promise
	return Promise.new(function(resolve, _, onCancel)
		local results: { [any]: any } = { n = #promises }
		local remaining = #promises
		onCancel(function()
			cancelAll(promises)
		end)
		if remaining == 0 then
			resolve(results)
			return
		end
		local function finished()
			remaining -= 1
			if remaining == 0 then
				resolve(results)
			end
		end
		for i, promise in ipairs(promises) do
			Promise.resolve(promise):andThen(function(value)
				results[i] = { Status = "Resolved", Value = value }
				finished()
			end, function(err)
				results[i] = { Status = if isCancelledError(err) then "Cancelled" else "Rejected", Error = err }
				finished()
			end)
		end
	end)
end

function Promise.race(promises: { any }): Promise
	return Promise.new(function(resolve, reject, onCancel)
		if #promises == 0 then
			reject("Promise.race: no promises given")
			return
		end
		onCancel(function()
			cancelAll(promises)
		end)
		for _, promise in ipairs(promises) do
			Promise.resolve(promise):andThen(resolve, reject)
		end
	end)
end

function Promise.some(promises: { any }, count: number): Promise
	assert(type(count) == "number" and count > 0 and count % 1 == 0, "Promise.some: count must be a positive integer")
	return Promise.new(function(resolve, reject, onCancel)
		local total = #promises
		if count > total then
			reject(("Promise.some: requested %d results from only %d promises"):format(count, total))
			return
		end
		local results: { [any]: any } = { n = 0 }
		local resolvedCount = 0
		local rejectedCount = 0
		local settled = false
		onCancel(function()
			cancelAll(promises)
		end)
		for _, promise in ipairs(promises) do
			Promise.resolve(promise):andThen(function(value)
				if settled then
					return
				end
				resolvedCount += 1
				results[resolvedCount] = value
				results.n = resolvedCount
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

function Promise.delay(seconds: number): Promise
	assert(type(seconds) == "number" and seconds >= 0, "Promise.delay: seconds must be non-negative")
	return Promise.new(function(resolve, _, onCancel)
		local delayThread = task.delay(seconds, resolve)
		onCancel(function()
			pcall(task.cancel, delayThread)
		end)
	end)
end

function Promise.retry(fn: () -> Promise, attempts: number): Promise
	assert(type(fn) == "function", "Promise.retry: fn must be a function")
	assert(
		type(attempts) == "number" and attempts > 0 and attempts % 1 == 0,
		"Promise.retry: attempts must be a positive integer"
	)
	return Promise.new(function(resolve, reject, onCancel)
		local current: any = nil
		local cancelled = false
		onCancel(function()
			cancelled = true
			if isPromise(current) then
				current:cancel("retry cancelled")
			end
		end)
		local function attempt(n: number)
			if cancelled then
				return
			end
			local ok, promiseOrError = pcall(fn)
			if not ok or not isPromise(promiseOrError) then
				local err = if ok then "Promise.retry: fn must return a Promise" else promiseOrError
				if n >= attempts then
					reject(err)
				else
					task.spawn(attempt, n + 1)
				end
				return
			end
			current = promiseOrError
			promiseOrError:andThen(resolve, function(err)
				if cancelled then
					return
				end
				if n >= attempts then
					reject(err)
				else
					task.spawn(attempt, n + 1)
				end
			end)
		end
		attempt(1)
	end)
end

export type EventLike = { Connect: (self: any, fn: (...any) -> ()) -> { Disconnect: (self: any) -> () } }

function Promise.fromEvent(event: RBXScriptSignal | EventLike, predicate: ((...any) -> boolean)?): Promise
	return Promise.new(function(resolve, reject, onCancel)
		local connection: any = nil
		local settled = false
		local function disconnect()
			if connection then
				connection:Disconnect()
				connection = nil
			end
		end
		onCancel(disconnect)
		connection = event:Connect(function(...)
			if predicate then
				local ok, matches = pcall(predicate, ...)
				if not ok then
					disconnect()
					settled = true
					reject(matches)
					return
				end
				if not matches then
					return
				end
			end
			disconnect()
			settled = true
			local n = select("#", ...)
			if n <= 1 then
				resolve(...)
			else
				resolve(table.pack(...))
			end
		end)
		if settled then
			disconnect()
		end
	end)
end

function Promise:andThen(onResolve: ((any) -> any)?, onReject: ((any) -> any)?): Promise
	self._handled = true
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
		elseif self._state == "Rejected" or self._state == "Cancelled" then
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

function Promise:finally(callback: () -> any): Promise
	assert(type(callback) == "function", "Promise:finally expects a function")
	return self:andThen(function(value)
		return Promise.resolve(callback()):andThen(function()
			return value
		end)
	end, function(err)
		return Promise.resolve(callback()):andThen(function()
			error(err, 0)
		end)
	end)
end

function Promise:timeout(seconds: number, timeoutError: any?): Promise
	assert(type(seconds) == "number" and seconds >= 0, "Promise:timeout seconds must be non-negative")
	return Promise.new(function(resolve, reject, onCancel)
		local settled = false
		local timer = task.delay(seconds, function()
			if not settled then
				settled = true
				reject(timeoutError or ("Promise timed out after %.3gs"):format(seconds))
			end
		end)
		onCancel(function()
			pcall(task.cancel, timer)
		end)
		self:andThen(function(value)
			if not settled then
				settled = true
				pcall(task.cancel, timer)
				resolve(value)
			end
		end, function(err)
			if not settled then
				settled = true
				pcall(task.cancel, timer)
				reject(err)
			end
		end)
	end)
end

function Promise:cancel(reason: any?): boolean
	if self._state ~= "Pending" then
		return false
	end
	local hooks = self._cancelHooks
	self._cancelHooks = {}
	local adopted = self._adopted
	self._rejectInternal(makeCancellationError(reason))
	if isPromise(adopted) and adopted:getState() == "Pending" then
		adopted:cancel("adopting promise cancelled")
	end
	for _, callback in ipairs(hooks) do
		local ok, err = pcall(callback)
		if not ok then
			warn("[Promise] Cancellation hook failed:", err)
		end
	end
	return true
end

function Promise:await(): any
	self._handled = true
	if self._state == "Resolved" then
		return self._value
	end
	if self._state == "Rejected" or self._state == "Cancelled" then
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
