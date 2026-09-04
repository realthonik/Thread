--!strict

local Thread = {}
local Channel = require(script.Channel)
local Promise = require(script.Promise)
local Metadata = require(script.Generated.Metadata)
local GeneratedServiceManifest = require(script.Generated.ServiceManifest) :: {
	[string]: { { Name: string, Kind: string, Class: string } },
}
local GeneratedClients = require(script.Generated.Clients)

export type Middleware = Channel.Middleware
export type ServiceDef = {
	Name: string,
	Client: { [any]: any }?,
	Dependencies: { string }?,
	Middleware: Middleware?,
	RemotePolicies: { [string]: Channel.RemotePolicy }?,
	Critical: boolean?,
	RateLimit: number?,
	InvokeRateLimit: number?,
	MaxPayloadBytes: number?,
	ThreadInit: ((self: any) -> any)?,
	ThreadStart: ((self: any) -> any)?,
	ThreadStop: ((self: any) -> any)?,
	[any]: any,
}
export type Service = ServiceDef
export type RegisterResult = {
	Module: ModuleScript,
	Success: boolean,
	Result: any,
	Error: any,
}

Thread.Version = Metadata.Version
Thread.Metadata = Metadata
Thread.GeneratedServiceManifest = GeneratedServiceManifest
Thread.Clients = GeneratedClients
Thread.Debug = false
Thread.HaltOnCriticalFailure = false
Thread._Register = {} :: { [string]: Service }
Thread._Started = false
Thread._Stopped = false
Thread._StartResolved = false
Thread._Order = {} :: { string }
Thread._Status = {} :: { [string]: string }
Thread._NeedsStop = {} :: { [string]: boolean }

local StartPromise = Promise.new(function(resolve, reject)
	Thread._ResolveStart = resolve
	Thread._RejectStart = reject
end)
local StopPromise = Promise.new(function(resolve, reject)
	Thread._ResolveStop = resolve
	Thread._RejectStop = reject
end)
Thread._StopStarted = false

local function ObserveLifecycle(promise)
	return promise:andThen(function(value)
		return value
	end)
end

local function Log(...)
	if Thread.Debug then
		print("[Thread]", ...)
	end
end

local function Warn(...)
	warn("[Thread]", ...)
end

function Thread.Configure(config: { Debug: boolean?, HaltOnCriticalFailure: boolean? })
	assert(type(config) == "table", "Thread.Configure expects a table")
	for key in pairs(config :: any) do
		assert(
			key == "Debug" or key == "HaltOnCriticalFailure",
			("Thread.Configure: unknown option '%s'"):format(tostring(key))
		)
	end
	if config.Debug ~= nil then
		assert(type(config.Debug) == "boolean", "Thread.Configure: Debug must be a boolean")
		Thread.Debug = config.Debug
		Thread.Channel.Debug = config.Debug
	end
	if config.HaltOnCriticalFailure ~= nil then
		assert(
			type(config.HaltOnCriticalFailure) == "boolean",
			"Thread.Configure: HaltOnCriticalFailure must be a boolean"
		)
		Thread.HaltOnCriticalFailure = config.HaltOnCriticalFailure
	end
end

Thread.Channel = Channel
Thread.Promise = Promise
Thread.CreateSignal = Channel.CreateSignal
Thread.CreateUnreliableSignal = Channel.CreateUnreliableSignal
Thread.CreateProperty = Channel.CreateProperty
Thread.Validators = Channel.Validators
Thread.Signal = require(script.Util.Signal)
Thread.Trove = require(script.Util.Trove)
Thread.TableUtil = require(script.Util.TableUtil)
Thread.Option = require(script.Util.Option)
Thread.EnumList = require(script.Util.EnumList)
Thread.MathUtil = require(script.Util.MathUtil)
Thread.TimerUtil = require(script.Util.TimerUtil)

function Thread.CreateService(service: ServiceDef): Service
	assert(type(service) == "table", "Thread.CreateService expects a table")
	assert(not Thread._Started, "Cannot create a service after Thread.Start()")
	assert(type(service.Name) == "string" and #service.Name > 0, "Service requires a non-empty Name")
	if service.Client ~= nil then
		assert(type(service.Client) == "table", "Service.Client must be a table")
	end
	if service.Dependencies ~= nil then
		assert(type(service.Dependencies) == "table", "Service.Dependencies must be a table of service names")
		local seen = {}
		local dependencyCount = 0
		for index, dependency in pairs(service.Dependencies) do
			assert(type(index) == "number" and index % 1 == 0 and index >= 1, "Service.Dependencies must be an array")
			assert(
				type(dependency) == "string" and #dependency > 0,
				"Service.Dependencies entries must be non-empty strings"
			)
			assert(
				not seen[dependency],
				("Service '%s' lists dependency '%s' more than once"):format(service.Name, dependency)
			)
			seen[dependency] = true
			dependencyCount += 1
		end
		assert(dependencyCount == #service.Dependencies, "Service.Dependencies must be a dense array")
	end
	if service.RemotePolicies ~= nil then
		assert(type(service.RemotePolicies) == "table", "Service.RemotePolicies must be a table")
		assert(type(service.Client) == "table", "Service.RemotePolicies requires a Client table")
	end
	if service.Critical ~= nil then
		assert(type(service.Critical) == "boolean", "Service.Critical must be a boolean")
	end
	for _, field in ipairs({ "ThreadInit", "ThreadStart", "ThreadStop" }) do
		local value = (service :: any)[field]
		assert(value == nil or type(value) == "function", ("Service.%s must be a function"):format(field))
	end
	for _, field in ipairs({ "RateLimit", "InvokeRateLimit", "MaxPayloadBytes" }) do
		local value = (service :: any)[field]
		if value ~= nil then
			assert(type(value) == "number" and value >= 0, ("Service.%s must be a non-negative number"):format(field))
			if field == "MaxPayloadBytes" then
				assert(value % 1 == 0, "Service.MaxPayloadBytes must be an integer")
			end
		end
	end
	if Thread._Register[service.Name] then
		error(("[Thread] Duplicate service name: '%s' is already registered"):format(service.Name), 0)
	end
	Thread._Register[service.Name] = service
	Thread._Status[service.Name] = "Registered"
	Log("Registered service:", service.Name)
	return service
end

function Thread.GetService(name: string): Service
	assert(type(name) == "string", "Thread.GetService expects a string")
	local service = Thread._Register[name]
	assert(service ~= nil, ("[Thread] No service named '%s' is registered"):format(name))
	return service
end

function Thread.GetServices(): { [string]: Service }
	return table.clone(Thread._Register)
end

function Thread.GetServiceStatus(name: string): string?
	return Thread._Status[name]
end

function Thread.Unregister(name: string): boolean
	assert(type(name) == "string", "Thread.Unregister expects a string")
	assert(not Thread._Started, "Cannot unregister after Thread.Start()")
	if Thread._Register[name] then
		Thread._Register[name] = nil
		Thread._Status[name] = nil
		Log("Unregistered service:", name)
		return true
	end
	return false
end

function Thread.Register(folder: Instance, recursive: boolean?): { RegisterResult }
	assert(typeof(folder) == "Instance", "Thread.Register expects an Instance (folder)")
	assert(not Thread._Started, "Cannot register after Thread.Start()")
	local results: { RegisterResult } = {}
	local function registerFolder(target: Instance)
		for _, module in ipairs(target:GetChildren()) do
			if module:IsA("ModuleScript") then
				local success, result = pcall(require, module)
				table.insert(results, {
					Module = module,
					Success = success,
					Result = if success then result else nil,
					Error = if success then nil else result,
				})
				if not success then
					Warn("Failed loading:", module.Name, result)
				end
			elseif recursive and module:IsA("Folder") then
				registerFolder(module)
			end
		end
	end
	registerFolder(folder)
	return results
end

local function TopoSort(register: { [string]: Service }): ({ string }?, string?)
	local order: { string } = {}
	local state: { [string]: "Visiting" | "Done" } = {}
	local errorMessage: string? = nil
	local names = {}
	for name in pairs(register) do
		table.insert(names, name)
	end
	table.sort(names)

	local function visit(name: string, stack: { string })
		if errorMessage or state[name] == "Done" then
			return
		end
		if state[name] == "Visiting" then
			errorMessage = ("Circular dependency detected: %s -> %s"):format(table.concat(stack, " -> "), name)
			return
		end
		local service = register[name]
		if not service then
			errorMessage = ("Service '%s' declares a dependency on unknown service '%s'"):format(
				stack[#stack] or "?",
				name
			)
			return
		end
		state[name] = "Visiting"
		table.insert(stack, name)
		if service.Dependencies then
			for _, dependency in ipairs(service.Dependencies) do
				visit(dependency, stack)
				if errorMessage then
					return
				end
			end
		end
		table.remove(stack)
		state[name] = "Done"
		table.insert(order, name)
	end

	for _, name in ipairs(names) do
		visit(name, {})
		if errorMessage then
			return nil, errorMessage
		end
	end
	return order, nil
end

local function AwaitLifecycle(service: Service, methodName: string): (boolean, any)
	local method = (service :: any)[methodName]
	if type(method) ~= "function" then
		return true, nil
	end
	local ok, result = xpcall(function()
		return method(service)
	end, function(err)
		return debug.traceback(tostring(err), 2)
	end)
	if not ok then
		return false, result
	end
	if Promise.is(result) then
		return xpcall(function()
			return result:await()
		end, function(err)
			return debug.traceback(tostring(err), 2)
		end)
	end
	return true, result
end

local function RejectStart(message: string)
	if Thread._StartResolved then
		return
	end
	Thread._StartResolved = true
	Thread._RejectStart(message)
	if Thread.HaltOnCriticalFailure then
		task.defer(error, "[Thread] " .. message, 0)
	else
		Warn(message)
	end
end

local function CompareGeneratedManifest(serviceName: string): string?
	local expected = GeneratedServiceManifest[serviceName]
	if expected == nil then
		return nil
	end
	local actual = Channel.GetServiceManifest(serviceName)
	if #actual ~= #expected then
		return ("generated manifest expects %d remotes, but the Client table exposes %d"):format(#expected, #actual)
	end
	for index, expectedEntry in ipairs(expected) do
		local actualEntry = actual[index]
		if
			not actualEntry
			or actualEntry.Name ~= expectedEntry.Name
			or actualEntry.Kind ~= expectedEntry.Kind
			or actualEntry.Class ~= expectedEntry.Class
		then
			return ("generated manifest entry %d does not match the Client table"):format(index)
		end
	end
	return nil
end

local function RunStartup()
	if Channel.IsServer then
		for serviceName in pairs(GeneratedServiceManifest) do
			if Thread._Register[serviceName] == nil then
				RejectStart(("Generated service '%s' was not registered"):format(serviceName))
				return
			end
		end
	end

	local amount = 0
	for _ in pairs(Thread._Register) do
		amount += 1
	end
	if amount == 0 then
		Warn("No services registered")
		Thread._StartResolved = true
		Thread._ResolveStart(Thread)
		return
	end

	local order, dependencyError = TopoSort(Thread._Register)
	if not order then
		RejectStart("Dependency resolution failed: " .. (dependencyError :: string))
		return
	end
	Thread._Order = order
	Log("Starting", amount, "services in dependency order:", table.concat(order, ", "))

	local failed: { [string]: string } = {}
	local wrapped: { [string]: boolean } = {}
	local criticalFailure: string? = nil
	local function recordFailure(name: string, phase: string, err: any)
		local message = ("Service '%s' failed %s: %s"):format(name, phase, tostring(err))
		failed[name] = message
		Thread._Status[name] = "Failed"
		Warn(message)
		if Thread._Register[name].Critical and not criticalFailure then
			criticalFailure = "Critical " .. message:sub(1, 1):lower() .. message:sub(2)
		end
	end
	local function failedDependency(name: string): string?
		for _, dependency in ipairs(Thread._Register[name].Dependencies or {}) do
			if failed[dependency] then
				return dependency
			end
		end
		return nil
	end
	local function destroyWrapped(allServices: boolean)
		for name in pairs(wrapped) do
			if allServices or failed[name] then
				Channel.Destroy(name)
				wrapped[name] = nil
			end
		end
	end

	for _, name in ipairs(order) do
		local service = Thread._Register[name]
		if Channel.IsServer and type(service.Client) == "table" then
			local ok, err = pcall(Channel.WrapService, name, service.Client, {
				Middleware = service.Middleware,
				Policies = service.RemotePolicies,
				RateLimit = service.RateLimit,
				InvokeRateLimit = service.InvokeRateLimit,
				MaxPayloadBytes = service.MaxPayloadBytes,
				DeferReady = true,
			})
			if ok then
				wrapped[name] = true
				Thread._Status[name] = "Bound"
			else
				Channel.Destroy(name)
				recordFailure(name, "Client remote binding", err)
			end
		end
		if Channel.IsServer and not failed[name] then
			local manifestError = CompareGeneratedManifest(name)
			if manifestError then
				Channel.Destroy(name)
				wrapped[name] = nil
				recordFailure(name, "generated manifest validation", manifestError)
				criticalFailure = ("Generated manifest mismatch for service '%s': %s"):format(name, manifestError)
			end
		end
	end
	if criticalFailure then
		destroyWrapped(true)
		RejectStart(criticalFailure)
		return
	end

	for _, name in ipairs(order) do
		local dependency = failedDependency(name)
		if dependency and not failed[name] then
			recordFailure(name, "dependency check", ("dependency '%s' did not initialize"):format(dependency))
		end
		if not failed[name] then
			Thread._NeedsStop[name] = true
			local ok, err = AwaitLifecycle(Thread._Register[name], "ThreadInit")
			if ok then
				Thread._Status[name] = "Initialized"
			else
				recordFailure(name, "ThreadInit", err)
			end
		end
		if criticalFailure then
			destroyWrapped(true)
			RejectStart(criticalFailure)
			return
		end
	end

	for _, name in ipairs(order) do
		local dependency = failedDependency(name)
		if dependency and not failed[name] then
			recordFailure(name, "dependency check", ("dependency '%s' did not start"):format(dependency))
		end
		if not failed[name] then
			local ok, err = AwaitLifecycle(Thread._Register[name], "ThreadStart")
			if ok then
				Thread._Status[name] = "Started"
			else
				recordFailure(name, "ThreadStart", err)
			end
		end
		if criticalFailure then
			destroyWrapped(true)
			RejectStart(criticalFailure)
			return
		end
	end

	destroyWrapped(false)
	for _, name in ipairs(order) do
		if wrapped[name] and not failed[name] then
			local ok, err = pcall(Channel.MarkServiceReady, name)
			if not ok then
				recordFailure(name, "ready publication", err)
				Channel.Destroy(name)
				wrapped[name] = nil
				if criticalFailure then
					destroyWrapped(true)
					RejectStart(criticalFailure)
					return
				end
			end
		end
	end

	Thread._StartResolved = true
	Thread._ResolveStart(Thread)
	Log("Thread startup complete")
end

function Thread.Start()
	if Thread._Started then
		Warn("Start called twice")
		return ObserveLifecycle(StartPromise)
	end
	assert(not Thread._Stopped, "Cannot start Thread after it has stopped")
	Thread._Started = true
	task.spawn(RunStartup)
	return ObserveLifecycle(StartPromise)
end

function Thread.OnStart()
	return ObserveLifecycle(StartPromise)
end

function Thread.Stop()
	if Thread._StopStarted then
		return ObserveLifecycle(StopPromise)
	end
	assert(Thread._Started, "Thread.Stop requires Thread.Start to have been called")
	Thread._StopStarted = true
	task.spawn(function()
		pcall(function()
			StartPromise:await()
		end)
		local errors = {}
		for index = #Thread._Order, 1, -1 do
			local name = Thread._Order[index]
			if Thread._NeedsStop[name] then
				local ok, err = AwaitLifecycle(Thread._Register[name], "ThreadStop")
				if not ok then
					table.insert(errors, ("Service '%s' failed ThreadStop: %s"):format(name, tostring(err)))
					Thread._Status[name] = "StopFailed"
				else
					Thread._Status[name] = "Stopped"
				end
			end
			if Channel.IsServer then
				Channel.Destroy(name)
			end
		end
		Thread._Stopped = true
		if #errors > 0 then
			Thread._RejectStop(table.concat(errors, "\n"))
		else
			Thread._ResolveStop(Thread)
		end
	end)
	return ObserveLifecycle(StopPromise)
end

function Thread.OnStop()
	return ObserveLifecycle(StopPromise)
end

return Thread
