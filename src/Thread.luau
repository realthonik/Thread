--!strict

local Thread = {}

--------------------------------------------------
-- Types
--------------------------------------------------

local Channel = require(script.Parent.Channel)

export type Middleware = Channel.Middleware

export type ServiceDef = {
	Name: string,
	Client: { [any]: any }?,
	Dependencies: { string }?,
	Middleware: Middleware?,
	Critical: boolean?,
	RateLimit: number?,
	InvokeRateLimit: number?,
	ThreadInit: ((self: any) -> ())?,
	ThreadStart: ((self: any) -> ())?,
	[any]: any,
}

export type Service = ServiceDef

export type RegisterResult = {
	Module: ModuleScript,
	Success: boolean,
	Result: any,
	Error: any,
}

--------------------------------------------------
-- State
--------------------------------------------------

Thread.Version = "1.0.1"
Thread.Debug = false
Thread.HaltOnCriticalFailure = false -- if true, a critical service failure hard-errors instead of just rejecting the start Promise

Thread._Register = {} :: { [string]: Service }
Thread._Started = false
Thread._StartResolved = false

--------------------------------------------------
-- Promise
--------------------------------------------------

local Promise = require(script.Parent.Promise)

local StartPromise = Promise.new(function(resolve, reject)
	Thread._ResolveStart = resolve
	Thread._RejectStart = reject
end)

--------------------------------------------------
-- Debug
--------------------------------------------------

local function Log(...)
	if Thread.Debug then
		print("[Thread]", ...)
	end
end

local function Warn(...)
	warn("[Thread]", ...)
end

--------------------------------------------------
-- Configuration
--------------------------------------------------

function Thread.Configure(config: { Debug: boolean?, HaltOnCriticalFailure: boolean? })
	assert(type(config) == "table", "Thread.Configure expects a table")

	if config.Debug ~= nil then
		Thread.Debug = config.Debug
		Thread.Channel.Debug = config.Debug
	end

	if config.HaltOnCriticalFailure ~= nil then
		Thread.HaltOnCriticalFailure = config.HaltOnCriticalFailure
	end
end

--------------------------------------------------
-- Channel
--------------------------------------------------

Thread.Channel = Channel

Thread.CreateSignal = Channel.CreateSignal
Thread.CreateUnreliableSignal = Channel.CreateUnreliableSignal
Thread.CreateProperty = Channel.CreateProperty

Log("Channel loaded")

--------------------------------------------------
-- Utilities
--------------------------------------------------
-- Standalone helpers bundled alongside Thread (each also requirable on its
-- own from Packages/Util/, with zero dependency on Thread itself).

Thread.Signal = require(script.Parent.Util.Signal)
Thread.Trove = require(script.Parent.Util.Trove)
Thread.TableUtil = require(script.Parent.Util.TableUtil)
Thread.Option = require(script.Parent.Util.Option)
Thread.EnumList = require(script.Parent.Util.EnumList)

--------------------------------------------------
-- Service Creation
--------------------------------------------------

function Thread.CreateService(service: ServiceDef): Service
	assert(type(service) == "table", "Thread.CreateService expects a table")
	assert(type(service.Name) == "string", "Service requires a Name")
	assert(#service.Name > 0, "Service.Name must be a non-empty string")

	if service.Client ~= nil then
		assert(type(service.Client) == "table", "Service.Client must be a table")
	end

	if service.Dependencies ~= nil then
		assert(type(service.Dependencies) == "table", "Service.Dependencies must be a table of service names")
	end

	if Thread._Register[service.Name] then
		error(("[Thread] Duplicate service name: '%s' is already registered"):format(service.Name), 0)
	end

	Thread._Register[service.Name] = service

	Log("Registered service:", service.Name)

	return service
end

--------------------------------------------------
-- Service Access
--------------------------------------------------

function Thread.GetService(name: string): Service
	assert(type(name) == "string", "Thread.GetService expects a string")

	local service = Thread._Register[name]

	assert(service ~= nil, ("[Thread] No service named '%s' is registered"):format(name))

	return service
end

-- Returns a shallow copy of every registered service, keyed by name.
function Thread.GetServices(): { [string]: Service }
	local copy = {}
	for name, service in pairs(Thread._Register) do
		copy[name] = service
	end
	return copy
end

-- Removes a registered service. Only valid before Thread.Start().
function Thread.Unregister(name: string): boolean
	assert(type(name) == "string", "Thread.Unregister expects a string")
	assert(not Thread._Started, "Cannot unregister after Thread.Start()")

	if Thread._Register[name] then
		Thread._Register[name] = nil
		Log("Unregistered service:", name)
		return true
	end

	return false
end

--------------------------------------------------
-- Register Modules
--------------------------------------------------

function Thread.Register(folder: Instance, recursive: boolean?): { RegisterResult }
	assert(typeof(folder) == "Instance", "Thread.Register expects an Instance (folder)")
	assert(not Thread._Started, "Cannot register after Thread.Start()")

	Log("Registering folder:", folder:GetFullName())

	local results: { RegisterResult } = {}

	local function registerFolder(target: Instance)
		for _, module in ipairs(target:GetChildren()) do
			if module:IsA("ModuleScript") then
				Log("Requiring module:", module.Name)

				local success, result = pcall(require, module)

				table.insert(results, {
					Module = module,
					Success = success,
					Result = success and result or nil,
					Error = (not success) and result or nil,
				})

				if success then
					Log("Loaded:", module.Name)
				else
					Warn("Failed loading:", module.Name, result)
				end
			elseif recursive and module:IsA("Folder") then
				registerFolder(module)
			end
		end
	end

	registerFolder(folder)

	Log("Folder loaded:", #results, "modules")

	return results
end

--------------------------------------------------
-- Dependency ordering
--------------------------------------------------

-- Kahn/DFS topological sort over Dependencies. Returns (order, nil) on
-- success, or (nil, errorMessage) if a cycle or unknown dependency exists.
local function TopoSort(register: { [string]: Service }): ({ string }?, string?)
	local order: { string } = {}
	local state: { [string]: "Visiting" | "Done" } = {}
	local errorMsg: string? = nil

	local function visit(name: string, stack: { string })
		if errorMsg then
			return
		end

		if state[name] == "Done" then
			return
		end

		if state[name] == "Visiting" then
			errorMsg = ("Circular dependency detected: %s -> %s"):format(table.concat(stack, " -> "), name)
			return
		end

		local service = register[name]

		if not service then
			errorMsg = ("Service '%s' declares a dependency on unknown service '%s'"):format(
				stack[#stack] or "?",
				name
			)
			return
		end

		state[name] = "Visiting"
		table.insert(stack, name)

		if type(service.Dependencies) == "table" then
			for _, dep in ipairs(service.Dependencies) do
				visit(dep, stack)
				if errorMsg then
					return
				end
			end
		end

		table.remove(stack)
		state[name] = "Done"
		table.insert(order, name)
	end

	for name in pairs(register) do
		visit(name, {})
		if errorMsg then
			return nil, errorMsg
		end
	end

	return order, nil
end

--------------------------------------------------
-- Start Framework
--------------------------------------------------

local function Fail(message: string)
	if not Thread._StartResolved then
		Thread._StartResolved = true
		Thread._RejectStart(message)
	end

	if Thread.HaltOnCriticalFailure then
		error("[Thread] " .. message, 0)
	else
		Warn(message)
	end

	return Thread.OnStart()
end

function Thread.Start()
	if Thread._Started then
		Warn("Start called twice")
		return Thread.OnStart()
	end

	Thread._Started = true

	local amount = 0
	for _ in pairs(Thread._Register) do
		amount += 1
	end

	if amount == 0 then
		Warn("No services registered")

		Thread._ResolveStart(Thread)
		Thread._StartResolved = true

		return Thread.OnStart()
	end

	local order, depErr = TopoSort(Thread._Register)

	if not order then
		return Fail("Dependency resolution failed: " .. (depErr :: string))
	end

	Log("Starting", amount, "services in dependency order:", table.concat(order, ", "))

	--------------------------------------------------
	-- Bind Client remotes (before Init, so services can
	-- use their own Signals/Properties inside ThreadInit)
	--------------------------------------------------

	for _, name in ipairs(order) do
		local service = Thread._Register[name]

		if type(service.Client) == "table" then
			local ok, err = pcall(Channel.WrapService, name, service.Client, {
				Middleware = service.Middleware,
				RateLimit = service.RateLimit,
				InvokeRateLimit = service.InvokeRateLimit,
			})

			if not ok then
				Warn("Failed to bind Client remotes for", name, ":", err)
			end
		end
	end

	local criticalFailure: string? = nil

	--------------------------------------------------
	-- Init
	--------------------------------------------------

	local initialized = 0

	for _, name in ipairs(order) do
		local service = Thread._Register[name]

		if type(service.ThreadInit) == "function" then
			Log("Initializing:", name)

			local success, err = xpcall(function()
				service:ThreadInit()
			end, debug.traceback)

			if success then
				initialized += 1
				Log("Initialized:", name)
			else
				Warn("Init failed:", name, err)

				if service.Critical and not criticalFailure then
					criticalFailure = ("Critical service '%s' failed ThreadInit: %s"):format(name, tostring(err))
				end
			end
		end
	end

	Log("Initialized", initialized, "/", amount)

	if criticalFailure then
		return Fail(criticalFailure)
	end

	--------------------------------------------------
	-- Start Services
	--------------------------------------------------

	local started = 0

	for _, name in ipairs(order) do
		local service = Thread._Register[name]

		if type(service.ThreadStart) == "function" then
			Log("Starting:", name)

			local success, err = xpcall(function()
				service:ThreadStart()
			end, debug.traceback)

			if success then
				started += 1
				Log("Started:", name)
			else
				Warn("Start failed:", name, err)

				if service.Critical and not criticalFailure then
					criticalFailure = ("Critical service '%s' failed ThreadStart: %s"):format(name, tostring(err))
				end
			end
		end
	end

	Log("Started", started, "/", amount)

	if criticalFailure then
		return Fail(criticalFailure)
	end

	Log("Thread startup complete ✓")

	if not Thread._StartResolved then
		Thread._StartResolved = true
		Thread._ResolveStart(Thread)
	end

	return Thread.OnStart()
end

--------------------------------------------------
-- Await Startup
--------------------------------------------------

function Thread.OnStart()
	return StartPromise
end

return Thread
