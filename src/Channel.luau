--!strict
--[[
	Channel - networking layer for Thread.

	Two APIs are exposed:

	1. Low-level (unchanged from v1.x, fully backwards compatible):
	   Channel.On / FireClient / FireAll / FireServer / SetFunction /
	   InvokeServer / InvokeClient / Event / Function

	2. Service-scoped (new): Channel.WrapService (server) + Channel.BuildClient
	   (client) let a service expose a typed `Client` table (methods,
	   Signals, Properties) the same way it's called - no more manually
	   matching string names between server and client.

	No external dependencies. Everything here is plain Luau + Roblox
	engine APIs (Instance, Attributes, RemoteEvent/RemoteFunction/
	UnreliableRemoteEvent).
]]

local Channel = {}

Channel.Debug = false
Channel.DefaultRateLimit = 30 -- max calls / second / player / remote for Signals & Channel.On
Channel.DefaultInvokeRateLimit = 20 -- max calls / second / player / remote for Methods & Channel.SetFunction
Channel.InvokeClientTimeout = 10 -- seconds before Channel.InvokeClient gives up
Channel.WaitTimeout = 10 -- seconds before any WaitForChild gives up

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local IsServer = RunService:IsServer()

--------------------------------------------------
-- Types
--------------------------------------------------

export type MiddlewareFn = (player: Player, args: { any }) -> boolean
export type MiddlewareList = { MiddlewareFn }
export type Middleware = {
	Inbound: MiddlewareList?,
	Outbound: MiddlewareList?,
}

export type WrapOptions = {
	Middleware: Middleware?,
	RateLimit: number?,
	InvokeRateLimit: number?,
}

--------------------------------------------------
-- Debug
--------------------------------------------------

local function Log(...)
	if Channel.Debug then
		print("[Channel]", ...)
	end
end

local function Warn(...)
	warn("[Channel]", ...)
end

function Channel.Configure(config: { [string]: any })
	assert(type(config) == "table", "Channel.Configure expects a table")
	for key, value in pairs(config) do
		if Channel[key] ~= nil then
			Channel[key] = value
		end
	end
end

--------------------------------------------------
-- Rate Limiting
--------------------------------------------------

local RateBuckets = {} -- [player] = { [bucketKey] = { count = n, windowStart = t } }

local function CheckRateLimit(player: Player?, bucketKey: string, limit: number): boolean
	if not IsServer or not player then
		return true
	end

	local now = os.clock()

	RateBuckets[player] = RateBuckets[player] or {}
	local bucket = RateBuckets[player][bucketKey]

	if not bucket or (now - bucket.windowStart) >= 1 then
		bucket = { count = 0, windowStart = now }
		RateBuckets[player][bucketKey] = bucket
	end

	bucket.count += 1

	if bucket.count > limit then
		Warn("Rate limit exceeded:", player.Name, bucketKey, ("(%d/%d per second)"):format(bucket.count, limit))
		return false
	end

	return true
end

if IsServer then
	Players.PlayerRemoving:Connect(function(player)
		RateBuckets[player] = nil
	end)
end

--------------------------------------------------
-- Middleware
--------------------------------------------------

-- Runs each middleware fn in order. A fn may mutate `args` in place to
-- transform them, and returns `false` to stop the chain (drop the call).
local function RunMiddleware(list: MiddlewareList?, player: Player?, args: { any }): boolean
	if not list then
		return true
	end

	for _, fn in ipairs(list) do
		local ok, shouldContinue = pcall(fn, player :: Player, args)
		if not ok then
			Warn("Middleware error:", shouldContinue)
			return false
		end
		if shouldContinue == false then
			return false
		end
	end

	return true
end

--------------------------------------------------
-- Folder Setup
--------------------------------------------------

local function GetOrCreateFolder(parent: Instance, name: string): Instance
	local folder = parent:FindFirstChild(name)

	if folder then
		return folder
	end

	if IsServer then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = parent
		Log("Created folder:", name, "under", parent:GetFullName())
		return folder
	end

	folder = parent:WaitForChild(name, Channel.WaitTimeout)

	if not folder then
		error(
			("[Channel] '%s' never appeared under '%s' (timed out after %ds). Make sure the server requires Thread before any client Channel calls."):format(
				name,
				parent:GetFullName(),
				Channel.WaitTimeout
			),
			0
		)
	end

	return folder
end

local Root = GetOrCreateFolder(ReplicatedStorage, "ThreadChannel")

local Cache: { [string]: Instance } = {}
local Containers: { [string]: Instance } = {}

--------------------------------------------------
-- Containers (optionally namespaced per-service)
--------------------------------------------------

local function GetContainer(class: string, namespace: string?): Instance
	local key = namespace and (class .. "\1" .. namespace) or class

	if Containers[key] then
		return Containers[key]
	end

	local classFolder = GetOrCreateFolder(Root, class)
	local container = classFolder

	if namespace then
		container = GetOrCreateFolder(classFolder, namespace)
	end

	Containers[key] = container

	return container
end

--------------------------------------------------
-- Get/Create
--------------------------------------------------

local function Get(class: string, name: string, namespace: string?): Instance
	assert(type(class) == "string", "[Channel] class must be a string")
	assert(type(name) == "string", "[Channel] name must be a string")

	local cacheKey = namespace and (class .. "\1" .. namespace .. "\1" .. name) or (class .. "\1" .. name)

	if Cache[cacheKey] then
		return Cache[cacheKey]
	end

	local container = GetContainer(class, namespace)
	local object = container:FindFirstChild(name)

	if not object then
		local isBindable = (class == "BindableEvent" or class == "BindableFunction")

		if IsServer or isBindable then
			object = Instance.new(class :: any)
			object.Name = name
			object.Parent = container

			Log("Created:", class, namespace and (namespace .. "." .. name) or name)
		else
			object = container:WaitForChild(name, Channel.WaitTimeout)

			if not object then
				error(
					("[Channel] '%s' (%s) does not exist after waiting %ds. Did the server register it?"):format(
						name,
						class,
						Channel.WaitTimeout
					),
					0
				)
			end
		end
	end

	Cache[cacheKey] = object :: Instance

	return object :: Instance
end

--------------------------------------------------
-- Low-level: Remote Events
--------------------------------------------------

function Channel.On(name: string, callback: (...any) -> (), rateLimit: number?)
	assert(type(name) == "string", "Channel.On: name must be a string")
	assert(type(callback) == "function", "Channel.On: callback must be a function")

	local remote = Get("RemoteEvent", name) :: RemoteEvent
	rateLimit = rateLimit or Channel.DefaultRateLimit

	Log("Connected:", name)

	if IsServer then
		return remote.OnServerEvent:Connect(function(player, ...)
			if not CheckRateLimit(player, name, rateLimit :: number) then
				return
			end

			local success, err = pcall(callback, player, ...)

			if not success then
				Warn("Handler error for", name, "from", player.Name, ":", err)
			end
		end)
	else
		return remote.OnClientEvent:Connect(function(...)
			local success, err = pcall(callback, ...)

			if not success then
				Warn("Handler error for", name, ":", err)
			end
		end)
	end
end

function Channel.FireClient(name: string, player: Player, ...: any)
	assert(IsServer, "FireClient only server")
	assert(type(name) == "string", "Channel.FireClient: name must be a string")
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Channel.FireClient: player must be a Player")

	Log("FireClient:", name, player.Name)

	local remote = Get("RemoteEvent", name) :: RemoteEvent
	local success, err = pcall(function(...)
		remote:FireClient(player, ...)
	end, ...)

	if not success then
		Warn("FireClient failed:", name, player.Name, err)
	end
end

function Channel.FireAll(name: string, ...: any)
	assert(IsServer, "FireAll only server")
	assert(type(name) == "string", "Channel.FireAll: name must be a string")

	Log("FireAll:", name)

	local remote = Get("RemoteEvent", name) :: RemoteEvent
	local success, err = pcall(function(...)
		remote:FireAllClients(...)
	end, ...)

	if not success then
		Warn("FireAll failed:", name, err)
	end
end

function Channel.FireServer(name: string, ...: any)
	assert(not IsServer, "FireServer only client")
	assert(type(name) == "string", "Channel.FireServer: name must be a string")

	Log("FireServer:", name)

	local remote = Get("RemoteEvent", name) :: RemoteEvent
	local success, err = pcall(function(...)
		remote:FireServer(...)
	end, ...)

	if not success then
		Warn("FireServer failed:", name, err)
	end
end

--------------------------------------------------
-- Low-level: Remote Functions
--------------------------------------------------

function Channel.SetFunction(name: string, callback: (...any) -> any, rateLimit: number?)
	assert(type(name) == "string", "Channel.SetFunction: name must be a string")
	assert(type(callback) == "function", "Channel.SetFunction: callback must be a function")

	local remote = Get("RemoteFunction", name) :: RemoteFunction
	rateLimit = rateLimit or Channel.DefaultInvokeRateLimit

	Log("Set function:", name)

	if IsServer then
		remote.OnServerInvoke = function(player, ...)
			if not CheckRateLimit(player, name, rateLimit :: number) then
				return nil
			end

			local success, result = pcall(callback, player, ...)

			if not success then
				Warn("Function error for", name, "from", player.Name, ":", result)
				return nil
			end

			return result
		end
	else
		remote.OnClientInvoke = function(...)
			local success, result = pcall(callback, ...)

			if not success then
				Warn("Function error for", name, ":", result)
				return nil
			end

			return result
		end
	end
end

function Channel.InvokeServer(name: string, ...: any): any
	assert(not IsServer, "InvokeServer only client")
	assert(type(name) == "string", "Channel.InvokeServer: name must be a string")

	Log("InvokeServer:", name)

	return (Get("RemoteFunction", name) :: RemoteFunction):InvokeServer(...)
end

function Channel.InvokeClient(name: string, player: Player, ...: any): any
	assert(IsServer, "InvokeClient only server")
	assert(type(name) == "string", "Channel.InvokeClient: name must be a string")
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Channel.InvokeClient: player must be a Player")

	local remote = Get("RemoteFunction", name) :: RemoteFunction
	local args = { ... }

	Log("InvokeClient:", name, player.Name)

	local thread = coroutine.running()
	local settled = false

	task.spawn(function()
		local success, result = pcall(function()
			return remote:InvokeClient(player, table.unpack(args))
		end)

		if settled then
			return
		end

		settled = true
		task.spawn(thread, success, result)
	end)

	task.delay(Channel.InvokeClientTimeout, function()
		if settled then
			return
		end

		settled = true
		task.spawn(
			thread,
			false,
			("InvokeClient '%s' to %s timed out after %ds"):format(name, player.Name, Channel.InvokeClientTimeout)
		)
	end)

	local success, result = coroutine.yield()

	if not success then
		Warn("InvokeClient failed:", name, player.Name, result)
		return nil
	end

	return result
end

--------------------------------------------------
-- Low-level: Bindables
--------------------------------------------------

function Channel.Event(name: string): BindableEvent
	assert(type(name) == "string", "Channel.Event: name must be a string")
	Log("BindableEvent:", name)
	return Get("BindableEvent", name) :: BindableEvent
end

function Channel.Function(name: string): BindableFunction
	assert(type(name) == "string", "Channel.Function: name must be a string")
	Log("BindableFunction:", name)
	return Get("BindableFunction", name) :: BindableFunction
end

--------------------------------------------------
-- Service-scoped API: markers
--------------------------------------------------

local SIGNAL_MARKER = newproxy(true)
;(getmetatable(SIGNAL_MARKER) :: any).__tostring = function()
	return "SIGNAL_MARKER"
end

local UNRELIABLE_SIGNAL_MARKER = newproxy(true)
;(getmetatable(UNRELIABLE_SIGNAL_MARKER) :: any).__tostring = function()
	return "UNRELIABLE_SIGNAL_MARKER"
end

local PROPERTY_MARKER = newproxy(true)
;(getmetatable(PROPERTY_MARKER) :: any).__tostring = function()
	return "PROPERTY_MARKER"
end

function Channel.CreateSignal()
	return SIGNAL_MARKER
end

function Channel.CreateUnreliableSignal()
	return UNRELIABLE_SIGNAL_MARKER
end

function Channel.CreateProperty(initialValue: any)
	return { PROPERTY_MARKER, initialValue }
end

--------------------------------------------------
-- Service-scoped API: Signal object
--------------------------------------------------

local Signal = {}
Signal.__index = Signal

function Signal.new(
	remote: RemoteEvent | UnreliableRemoteEvent,
	bucketKey: string,
	rateLimit: number?,
	inbound: MiddlewareList?,
	outbound: MiddlewareList?
)
	return setmetatable({
		_remote = remote,
		_bucketKey = bucketKey,
		_rateLimit = rateLimit or Channel.DefaultRateLimit,
		_inbound = inbound,
		_outbound = outbound,
	}, Signal)
end

-- Server: Signal:Fire(player, ...) fires to exactly one client. Runs Outbound
-- middleware (if any) first; middleware returning false drops the send.
-- Client: Signal:Fire(...) fires to the server (no middleware here - Inbound
-- middleware runs on the receiving end, inside :Connect, below).
function Signal:Fire(...: any)
	if IsServer then
		local player = ...
		assert(typeof(player) == "Instance" and player:IsA("Player"), "Signal:Fire (server) expects a Player as the first argument")

		local args = table.pack(...)
		local outArgs = { table.unpack(args, 2, args.n) }

		if self._outbound and not RunMiddleware(self._outbound, player, outArgs) then
			return
		end

		local ok, err = pcall(function()
			self._remote:FireClient(player, table.unpack(outArgs))
		end)

		if not ok then
			Warn("Signal:Fire failed:", err)
		end
	else
		local ok, err = pcall(function(...)
			self._remote:FireServer(...)
		end, ...)

		if not ok then
			Warn("Signal:Fire failed:", err)
		end
	end
end

function Signal:FireAll(...: any)
	assert(IsServer, "Signal:FireAll is server-only")

	local outArgs = { ... }
	if self._outbound and not RunMiddleware(self._outbound, nil, outArgs) then
		return
	end

	self._remote:FireAllClients(table.unpack(outArgs))
end

function Signal:FireExcept(exceptPlayer: Player, ...: any)
	assert(IsServer, "Signal:FireExcept is server-only")

	local outArgs = { ... }
	if self._outbound and not RunMiddleware(self._outbound, nil, outArgs) then
		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= exceptPlayer then
			self._remote:FireClient(player, table.unpack(outArgs))
		end
	end
end

function Signal:Connect(fn: (...any) -> ())
	assert(type(fn) == "function", "Signal:Connect expects a function")

	if IsServer then
		return (self._remote :: RemoteEvent).OnServerEvent:Connect(function(player, ...)
			if self._bucketKey and not CheckRateLimit(player, self._bucketKey, self._rateLimit) then
				return
			end

			local inArgs = { ... }
			if self._inbound and not RunMiddleware(self._inbound, player, inArgs) then
				return
			end

			local ok, err = pcall(fn, player, table.unpack(inArgs))
			if not ok then
				Warn("Signal handler error:", err)
			end
		end)
	else
		return self._remote.OnClientEvent:Connect(function(...)
			local ok, err = pcall(fn, ...)
			if not ok then
				Warn("Signal handler error:", err)
			end
		end)
	end
end

function Signal:Destroy()
	self._remote:Destroy()
end

--------------------------------------------------
-- Service-scoped API: Property object
--------------------------------------------------

local Property = {}
Property.__index = Property

function Property.new(remoteEvent: RemoteEvent, remoteFunction: RemoteFunction, initialValue: any?, outbound: MiddlewareList?)
	local self = setmetatable({
		_remoteEvent = remoteEvent,
		_remoteFunction = remoteFunction,
		_value = initialValue,
		_overrides = {} :: { [Player]: any }, -- server-only: per-player value overrides
		_observers = {} :: { (any) -> () },
		_playerRemovingConnection = nil :: RBXScriptConnection?,
		_outbound = outbound,
	}, Property)

	if IsServer then
		self._remoteFunction.OnServerInvoke = function(player)
			local override = self._overrides[player]
			if override ~= nil then
				return override
			end
			return self._value
		end

		self._playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
			self._overrides[player] = nil
		end)
	else
		local ok, value = pcall(function()
			return self._remoteFunction:InvokeServer()
		end)

		if ok then
			self._value = value
		end

		self._remoteEvent.OnClientEvent:Connect(function(newValue)
			self._value = newValue
			for _, fn in ipairs(self._observers) do
				task.spawn(fn, newValue)
			end
		end)
	end

	return self
end

-- Client: the last value received. Server: the default value (per-player
-- overrides are only visible to that player - use :GetFor(player) instead).
function Property:Get(): any
	return self._value
end

-- Sets the default value and broadcasts it to every client that doesn't
-- currently have a per-player override (see :SetFor). Runs Outbound
-- middleware (if any) first; middleware returning false drops the Set
-- entirely (the stored value is left unchanged).
function Property:Set(value: any)
	assert(IsServer, "Property:Set is server-only")

	local outArgs = { value }
	if self._outbound and not RunMiddleware(self._outbound, nil, outArgs) then
		return
	end
	value = outArgs[1]

	self._value = value

	for _, player in ipairs(Players:GetPlayers()) do
		if self._overrides[player] == nil then
			self._remoteEvent:FireClient(player, value)
		end
	end
end

-- Sets a value visible only to `player`, overriding the shared default
-- until :ClearFor(player) is called or the player leaves. Runs Outbound
-- middleware (if any) first, the same way :Set does.
function Property:SetFor(player: Player, value: any)
	assert(IsServer, "Property:SetFor is server-only")
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Property:SetFor expects a Player")

	local outArgs = { value }
	if self._outbound and not RunMiddleware(self._outbound, player, outArgs) then
		return
	end
	value = outArgs[1]

	self._overrides[player] = value
	self._remoteEvent:FireClient(player, value)
end

function Property:GetFor(player: Player): any
	assert(IsServer, "Property:GetFor is server-only")

	local override = self._overrides[player]
	if override ~= nil then
		return override
	end
	return self._value
end

-- Removes `player`'s override, reverting them back to the shared default.
function Property:ClearFor(player: Player)
	assert(IsServer, "Property:ClearFor is server-only")

	if self._overrides[player] == nil then
		return
	end

	self._overrides[player] = nil
	self._remoteEvent:FireClient(player, self._value)
end

-- Client-only: calls `fn` once immediately with the current value, then
-- again on every subsequent change. Returns a connection with :Disconnect().
function Property:Observe(fn: (any) -> ())
	assert(not IsServer, "Property:Observe is client-only")
	assert(type(fn) == "function", "Property:Observe expects a function")

	table.insert(self._observers, fn)
	task.spawn(fn, self._value)

	return {
		Disconnect = function()
			local index = table.find(self._observers, fn)
			if index then
				table.remove(self._observers, index)
			end
		end,
	}
end

function Property:Destroy()
	if self._playerRemovingConnection then
		self._playerRemovingConnection:Disconnect()
		self._playerRemovingConnection = nil
	end
end

--------------------------------------------------
-- Service-scoped API: WrapService (server) / BuildClient (client)
--------------------------------------------------

-- Binds a service's `Client` table to real Remote instances. Functions
-- become RemoteFunctions, signal/property markers become Signal/Property
-- objects (mutating the table in place, same as the markers they replace).
function Channel.WrapService(serviceName: string, clientTable: { [any]: any }, opts: WrapOptions?)
	assert(IsServer, "Channel.WrapService is server-only")
	assert(type(serviceName) == "string", "Channel.WrapService: serviceName must be a string")
	assert(type(clientTable) == "table", "Channel.WrapService: clientTable must be a table")

	opts = opts or {}
	local middleware = opts.Middleware or {}
	local inbound = middleware.Inbound
	local outbound = middleware.Outbound
	local rateLimit = opts.RateLimit or Channel.DefaultRateLimit
	local invokeRateLimit = opts.InvokeRateLimit or Channel.DefaultInvokeRateLimit

	-- Marks the service as "wired" regardless of which Remote classes it
	-- ends up using. BuildClient waits on this single, always-created
	-- marker instead of blindly WaitForChild-ing every class folder (a
	-- service with only Methods, for example, never gets a RemoteEvent
	-- folder - without this marker, BuildClient would stall for the full
	-- WaitTimeout on that folder for no reason).
	local servicesFolder = GetOrCreateFolder(Root, "Services")
	GetOrCreateFolder(servicesFolder, serviceName)

	for key, value in pairs(clientTable) do
		if key == "Server" then
			continue
		end

		if type(key) ~= "string" then
			continue
		end

		if type(value) == "function" then
			local remote = Get("RemoteFunction", key, serviceName) :: RemoteFunction
			remote:SetAttribute("ThreadKind", "Method")

			local bucketKey = serviceName .. "." .. key

			remote.OnServerInvoke = function(player, ...)
				if not CheckRateLimit(player, bucketKey, invokeRateLimit) then
					return nil
				end

				local inArgs = { ... }
				if not RunMiddleware(inbound, player, inArgs) then
					return nil
				end

				local success, result = pcall(value, clientTable, player, table.unpack(inArgs))

				if not success then
					Warn("Client method error:", serviceName, key, "from", player.Name, ":", result)
					return nil
				end

				local outArgs = { result }
				if not RunMiddleware(outbound, player, outArgs) then
					return nil
				end

				return table.unpack(outArgs)
			end
		elseif value == SIGNAL_MARKER or value == UNRELIABLE_SIGNAL_MARKER then
			local class = (value == UNRELIABLE_SIGNAL_MARKER) and "UnreliableRemoteEvent" or "RemoteEvent"
			local remote = Get(class, key, serviceName) :: RemoteEvent
			remote:SetAttribute("ThreadKind", "Signal")

			local bucketKey = serviceName .. "." .. key
			clientTable[key] = Signal.new(remote, bucketKey, rateLimit, inbound, outbound)
		elseif type(value) == "table" and value[1] == PROPERTY_MARKER then
			local remoteEvent = Get("RemoteEvent", key, serviceName) :: RemoteEvent
			local remoteFunction = Get("RemoteFunction", key, serviceName) :: RemoteFunction
			remoteEvent:SetAttribute("ThreadKind", "Property")
			remoteFunction:SetAttribute("ThreadKind", "Property")

			clientTable[key] = Property.new(remoteEvent, remoteFunction, value[2], outbound)
		end
	end
end

-- Builds a client-side proxy for a service by inspecting the Remote
-- instances the server created via WrapService. Call proxy:Method(...) for
-- methods, proxy.SomeSignal:Connect(fn) for signals, proxy.SomeProp:Get()
-- for properties.
function Channel.BuildClient(serviceName: string, timeout: number?): { [string]: any }
	assert(not IsServer, "Channel.BuildClient is client-only")
	assert(type(serviceName) == "string", "Channel.BuildClient: serviceName must be a string")

	local waitTimeout = timeout or Channel.WaitTimeout

	-- Wait once on a single, always-created marker instead of blindly
	-- WaitForChild-ing every Remote class folder - a service that only
	-- exposes Methods, for example, never creates a RemoteEvent folder at
	-- all, and waiting on it would stall for no reason.
	local servicesFolder = Root:FindFirstChild("Services") or Root:WaitForChild("Services", waitTimeout)
	if not servicesFolder then
		error(
			("[Channel] No services have been wired yet (waited %ds). Make sure the server ran Thread.Start() before any client Channel.BuildClient calls."):format(
				waitTimeout
			),
			0
		)
	end

	local serviceFolder = servicesFolder:FindFirstChild(serviceName) or servicesFolder:WaitForChild(serviceName, waitTimeout)
	if not serviceFolder then
		error(
			("[Channel] Service '%s' was never wired by the server (waited %ds). Check the service name and that Thread.Start() ran on the server."):format(
				serviceName,
				waitTimeout
			),
			0
		)
	end

	local proxy: { [string]: any } = {}
	local pendingProperties: { [string]: { remoteEvent: RemoteEvent?, remoteFunction: RemoteFunction? } } = {}

	-- The service is confirmed to exist at this point, so a missing class
	-- folder here just means "this service doesn't use that Remote class" -
	-- no need to wait any further.
	local function scan(class: string)
		local classFolder = Root:FindFirstChild(class)
		if not classFolder then
			return
		end

		local nsFolder = classFolder:FindFirstChild(serviceName)
		if not nsFolder then
			return
		end

		for _, obj in ipairs(nsFolder:GetChildren()) do
			local kind = obj:GetAttribute("ThreadKind")
			local key = obj.Name
			local cacheKey = class .. "\1" .. serviceName .. "\1" .. key
			Cache[cacheKey] = obj

			if kind == "Method" then
				proxy[key] = function(_self, ...: any): any
					return (obj :: RemoteFunction):InvokeServer(...)
				end
			elseif kind == "Signal" then
				proxy[key] = Signal.new(obj :: any, serviceName .. "." .. key)
			elseif kind == "Property" then
				pendingProperties[key] = pendingProperties[key] or {}
				if obj:IsA("RemoteFunction") then
					pendingProperties[key].remoteFunction = obj
				else
					pendingProperties[key].remoteEvent = obj :: RemoteEvent
				end
			end
		end
	end

	scan("RemoteFunction")
	scan("RemoteEvent")
	scan("UnreliableRemoteEvent")

	for key, pair in pairs(pendingProperties) do
		if pair.remoteEvent and pair.remoteFunction then
			proxy[key] = Property.new(pair.remoteEvent, pair.remoteFunction)
		end
	end

	return proxy
end

-- Tears down every Remote created for a service (via WrapService) and
-- clears related caches. Intended for hot-reload / dynamic teardown in
-- Studio or tests - not something a typical live server needs to call.
function Channel.Destroy(serviceName: string)
	assert(type(serviceName) == "string", "Channel.Destroy expects a string")

	for _, class in ipairs({ "RemoteFunction", "RemoteEvent", "UnreliableRemoteEvent" }) do
		local classFolder = Root:FindFirstChild(class)
		if classFolder then
			local nsFolder = classFolder:FindFirstChild(serviceName)
			if nsFolder then
				nsFolder:Destroy()
			end
		end
		Containers[class .. "\1" .. serviceName] = nil
	end

	local servicesFolder = Root:FindFirstChild("Services")
	if servicesFolder then
		local marker = servicesFolder:FindFirstChild(serviceName)
		if marker then
			marker:Destroy()
		end
	end

	local prefix = serviceName .. "\1"
	for key in pairs(Cache) do
		if key:find(prefix, 1, true) then
			Cache[key] = nil
		end
	end

	Log("Destroyed service remotes:", serviceName)
end

return Channel
