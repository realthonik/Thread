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
Channel.DefaultMaxPayloadBytes = 64 * 1024
Channel.InvokeClientTimeout = 10 -- seconds before Channel.InvokeClient gives up
Channel.WaitTimeout = 10 -- seconds before any WaitForChild gives up

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local IsServer = RunService:IsServer()
Channel.IsServer = IsServer

--------------------------------------------------
-- Types
--------------------------------------------------

export type MiddlewareFn = (player: Player?, args: { any }) -> boolean
export type MiddlewareList = { MiddlewareFn }
export type Middleware = {
	Inbound: MiddlewareList?,
	Outbound: MiddlewareList?,
}

export type ValidatorFn = (value: any, index: number, player: Player?) -> (boolean, string?)
export type RemotePolicy = {
	Arguments: { ValidatorFn }?,
	AllowExtraArguments: boolean?,
	MaxPayloadBytes: number?,
	RateLimit: number?,
}

export type WrapOptions = {
	Middleware: Middleware?,
	Policies: { [string]: RemotePolicy }?,
	RateLimit: number?,
	InvokeRateLimit: number?,
	MaxPayloadBytes: number?,
	DeferReady: boolean?,
}

export type RemoteError = {
	ThreadRemoteError: true,
	Code: string,
	Message: string,
	Service: string,
	Remote: string,
	Details: any?,
}

local function PackArgs(...: any): { [any]: any }
	return table.pack(...)
end

local function UnpackArgs(args: { [any]: any }): ...any
	return table.unpack(args, 1, args.n or #args)
end

local function SliceArgs(args: { [any]: any }, first: number): { [any]: any }
	local last = args.n or #args
	local out: { [any]: any } = table.create(math.max(last - first + 1, 0))
	out.n = math.max(last - first + 1, 0)
	for i = first, last do
		out[i - first + 1] = args[i]
	end
	return out
end

--------------------------------------------------
-- Validation and structured service responses
--------------------------------------------------

local Validators = {}

local function TypeValidator(expectedType: string): ValidatorFn
	return function(value: any)
		local actualType = typeof(value)
		if actualType == expectedType then
			return true
		end
		return false, ("expected %s, got %s"):format(expectedType, actualType)
	end
end

Validators.Any = function(_value: any): (boolean, string?)
	return true, nil
end
Validators.String = TypeValidator("string")
Validators.Number = TypeValidator("number")
Validators.Boolean = TypeValidator("boolean")
Validators.Table = TypeValidator("table")
Validators.Instance = TypeValidator("Instance")
Validators.Player = function(value: any): (boolean, string?)
	if typeof(value) == "Instance" and value:IsA("Player") then
		return true, nil
	end
	return false, "expected Player"
end
Validators.Integer = function(value: any): (boolean, string?)
	if type(value) == "number" and value % 1 == 0 then
		return true, nil
	end
	return false, "expected integer"
end
Validators.FiniteNumber = function(value: any): (boolean, string?)
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return true, nil
	end
	return false, "expected finite number"
end

function Validators.Optional(validator: ValidatorFn): ValidatorFn
	assert(type(validator) == "function", "Validators.Optional expects a validator")
	return function(value: any, index: number, player: Player?)
		if value == nil then
			return true, nil
		end
		return validator(value, index, player)
	end
end

function Validators.StringMaxLength(maxLength: number): ValidatorFn
	assert(
		type(maxLength) == "number" and maxLength >= 0 and maxLength % 1 == 0,
		"Validators.StringMaxLength expects a non-negative integer"
	)
	return function(value: any)
		if type(value) ~= "string" then
			return false, "expected string"
		end
		if #value > maxLength then
			return false, ("string exceeds %d bytes"):format(maxLength)
		end
		return true, nil
	end
end

function Validators.Array(itemValidator: ValidatorFn?, maxLength: number?): ValidatorFn
	assert(
		itemValidator == nil or type(itemValidator) == "function",
		"Validators.Array item validator must be a function"
	)
	assert(
		maxLength == nil or (type(maxLength) == "number" and maxLength >= 0 and maxLength % 1 == 0),
		"Validators.Array maxLength must be a non-negative integer"
	)
	return function(value: any, _index: number, player: Player?)
		if type(value) ~= "table" then
			return false, "expected array"
		end
		local length = #value
		local count = 0
		for key in pairs(value) do
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then
				return false, "expected a dense array"
			end
			count += 1
		end
		if count ~= length then
			return false, "expected a dense array"
		end
		if maxLength and length > maxLength then
			return false, ("array exceeds %d items"):format(maxLength)
		end
		if itemValidator then
			for itemIndex, item in ipairs(value) do
				local ok, reason = itemValidator(item, itemIndex, player)
				if not ok then
					return false, ("array item %d: %s"):format(itemIndex, reason or "invalid value")
				end
			end
		end
		return true, nil
	end
end

Channel.Validators = table.freeze(Validators)

local RESPONSE_PROTOCOL = 1

local function MakeRemoteError(
	code: string,
	message: string,
	serviceName: string,
	remoteName: string,
	details: any?
): RemoteError
	return {
		ThreadRemoteError = true,
		Code = code,
		Message = message,
		Service = serviceName,
		Remote = remoteName,
		Details = details,
	}
end

function Channel.IsRemoteError(value: any): boolean
	return type(value) == "table" and value.ThreadRemoteError == true and type(value.Code) == "string"
end

local function SuccessResponse(values: { [any]: any }): { [string]: any }
	local encoded = table.create(values.n or #values)
	for index = 1, values.n or #values do
		encoded[index] = { HasValue = values[index] ~= nil, Value = values[index] }
	end
	return { ThreadProtocol = RESPONSE_PROTOCOL, Ok = true, Values = encoded }
end

local function ErrorResponse(remoteError: RemoteError): { [string]: any }
	return { ThreadProtocol = RESPONSE_PROTOCOL, Ok = false, Error = remoteError }
end

function Channel.DecodeResponse(response: any): ...any
	if type(response) ~= "table" or response.ThreadProtocol ~= RESPONSE_PROTOCOL then
		return response
	end
	if response.Ok ~= true then
		if Channel.IsRemoteError(response.Error) then
			error(response.Error, 0)
		end
		error(MakeRemoteError("MALFORMED_RESPONSE", "Server returned a malformed error response", "?", "?"), 0)
	end
	if type(response.Values) ~= "table" then
		error(MakeRemoteError("MALFORMED_RESPONSE", "Server returned malformed response values", "?", "?"), 0)
	end
	local values = response.Values
	local decoded: { [any]: any } = table.create(#values)
	decoded.n = #values
	for index, item in ipairs(values) do
		if type(item) ~= "table" or type(item.HasValue) ~= "boolean" then
			error(MakeRemoteError("MALFORMED_RESPONSE", "Server returned a malformed response item", "?", "?"), 0)
		end
		if item.HasValue then
			decoded[index] = item.Value
		end
	end
	return UnpackArgs(decoded)
end

local function EstimatePayloadBytes(
	value: any,
	seen: { [any]: boolean },
	depth: number,
	budget: number?
): (number?, string?)
	if depth > 32 then
		return nil, "payload nesting exceeds 32 levels"
	end
	local valueType = typeof(value)
	if value == nil then
		return 1, nil
	elseif valueType == "boolean" then
		return 1, nil
	elseif valueType == "number" then
		return 8, nil
	elseif valueType == "string" then
		return #value, nil
	elseif valueType == "buffer" then
		return buffer.len(value), nil
	elseif valueType == "Instance" or valueType == "EnumItem" then
		return 16, nil
	elseif valueType == "Vector2" or valueType == "Vector3" or valueType == "Color3" then
		return 24, nil
	elseif valueType == "CFrame" then
		return 96, nil
	elseif valueType == "function" or valueType == "thread" then
		return nil, ("unsupported payload type %s"):format(valueType)
	elseif valueType ~= "table" then
		return 64, nil
	end
	if seen[value] then
		return nil, "cyclic tables cannot be sent through remotes"
	end
	seen[value] = true
	local size = 8
	for key, item in pairs(value) do
		local keySize, keyError = EstimatePayloadBytes(key, seen, depth + 1, if budget then budget - size else nil)
		if not keySize then
			seen[value] = nil
			return nil, keyError
		end
		local itemSize, itemError =
			EstimatePayloadBytes(item, seen, depth + 1, if budget then budget - size - keySize else nil)
		if not itemSize then
			seen[value] = nil
			return nil, itemError
		end
		size += keySize + itemSize
		if budget and size > budget then
			seen[value] = nil
			return size, nil
		end
	end
	seen[value] = nil
	return size, nil
end

local function ValidateInbound(
	player: Player?,
	args: { [any]: any },
	policy: RemotePolicy?,
	defaultMaxPayloadBytes: number
): (boolean, string?, string?)
	local maxPayloadBytes = if policy and policy.MaxPayloadBytes ~= nil
		then policy.MaxPayloadBytes
		else defaultMaxPayloadBytes
	local size, sizeError = EstimatePayloadBytes(args, {}, 0, maxPayloadBytes)
	if not size then
		return false, "INVALID_PAYLOAD", sizeError
	end
	if size > maxPayloadBytes then
		return false,
			"PAYLOAD_TOO_LARGE",
			("payload is approximately %d bytes; limit is %d"):format(size, maxPayloadBytes)
	end
	if not policy or not policy.Arguments then
		return true, nil, nil
	end
	if policy.AllowExtraArguments == false and (args.n or #args) > #policy.Arguments then
		return false,
			"VALIDATION_FAILED",
			("expected at most %d arguments, got %d"):format(#policy.Arguments, args.n or #args)
	end
	for index, validator in ipairs(policy.Arguments) do
		if type(validator) ~= "function" then
			return false, "VALIDATION_FAILED", ("validator %d is not a function"):format(index)
		end
		local called, valid, reason = pcall(validator, args[index], index, player)
		if not called then
			return false, "VALIDATION_FAILED", ("validator %d failed: %s"):format(index, tostring(valid))
		end
		if not valid then
			return false, "VALIDATION_FAILED", ("argument %d: %s"):format(index, reason or "invalid value")
		end
	end
	return true, nil, nil
end

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
	local allowed: { [string]: string } = {
		Debug = "boolean",
		DefaultRateLimit = "number",
		DefaultInvokeRateLimit = "number",
		DefaultMaxPayloadBytes = "number",
		InvokeClientTimeout = "number",
		WaitTimeout = "number",
	}
	for key, value in pairs(config) do
		local expectedType = allowed[key]
		assert(expectedType ~= nil, ("Channel.Configure: unknown option '%s'"):format(tostring(key)))
		assert(type(value) == expectedType, ("Channel.Configure: %s must be a %s"):format(key, expectedType))
		if expectedType == "number" then
			assert(value >= 0, ("Channel.Configure: %s must be non-negative"):format(key))
			if key == "DefaultMaxPayloadBytes" then
				assert(value % 1 == 0, "Channel.Configure: DefaultMaxPayloadBytes must be an integer")
			end
		end
	end
	for key, value in pairs(config) do
		Channel[key] = value
	end
end

--------------------------------------------------
-- Rate Limiting
--------------------------------------------------

local RateBuckets = {} -- [player] = { [bucketKey] = { tokens, updatedAt } }
local WarningTimes = {} -- [player] = { [warningKey] = timestamp }

local function WarnRemoteThrottled(player: Player?, warningKey: string, ...: any)
	if not player then
		Warn(...)
		return
	end
	local now = os.clock()
	WarningTimes[player] = WarningTimes[player] or {}
	local previous = WarningTimes[player][warningKey]
	if previous == nil or now - previous >= 1 then
		WarningTimes[player][warningKey] = now
		Warn(...)
	end
end

local function CheckRateLimit(player: Player?, bucketKey: string, limit: number): boolean
	if not IsServer or not player then
		return true
	end

	local now = os.clock()
	local capacity = if limit > 0 then math.max(limit, 1) else 0

	RateBuckets[player] = RateBuckets[player] or {}
	local bucket = RateBuckets[player][bucketKey]

	if not bucket then
		bucket = { tokens = capacity, updatedAt = now }
		RateBuckets[player][bucketKey] = bucket
	end

	local elapsed = math.max(now - bucket.updatedAt, 0)
	bucket.updatedAt = now
	bucket.tokens = math.min(capacity, bucket.tokens + elapsed * limit)
	if bucket.tokens < 1 then
		WarnRemoteThrottled(
			player,
			bucketKey .. "\1RATE_LIMIT",
			"Rate limit exceeded:",
			player.Name,
			bucketKey,
			("(%.3g token capacity)"):format(limit)
		)
		return false
	end

	bucket.tokens -= 1
	return true
end

if IsServer then
	Players.PlayerRemoving:Connect(function(player)
		RateBuckets[player] = nil
		WarningTimes[player] = nil
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
		assert(
			folder:IsA("Folder"),
			("[Channel] Expected '%s' under '%s' to be a Folder, got %s"):format(
				name,
				parent:GetFullName(),
				folder.ClassName
			)
		)
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
			("[Channel] '%s' never appeared under '%s' (timed out after %.3gs). Make sure the server requires Thread before any client Channel calls."):format(
				name,
				parent:GetFullName(),
				Channel.WaitTimeout
			),
			0
		)
	end
	assert(
		folder:IsA("Folder"),
		("[Channel] Expected '%s' under '%s' to be a Folder, got %s"):format(
			name,
			parent:GetFullName(),
			folder.ClassName
		)
	)

	return folder
end

local Root = GetOrCreateFolder(ReplicatedStorage, "ThreadChannel")

local Cache: { [string]: Instance } = {}
local Containers: { [string]: Instance } = {}
local ServiceObjects: { [string]: { any } } = {}
local ServiceReady: { [string]: boolean } = {}
local ServiceManifests: { [string]: { { Name: string, Kind: string, Class: string } } } = {}
local RemoteClasses = { "RemoteFunction", "RemoteEvent", "UnreliableRemoteEvent" }

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
		local cached = Cache[cacheKey]
		if cached.Parent and cached:IsA(class) then
			return cached
		end
		Cache[cacheKey] = nil
	end

	local container = GetContainer(class, namespace)
	local object = container:FindFirstChild(name)
	if object and not object:IsA(class) then
		error(("[Channel] Expected '%s' to be a %s, got %s"):format(object:GetFullName(), class, object.ClassName), 0)
	end

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
					("[Channel] '%s' (%s) does not exist after waiting %.3gs. Did the server register it?"):format(
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
	assert(
		rateLimit == nil or (type(rateLimit) == "number" and rateLimit >= 0),
		"Channel.On: rateLimit must be non-negative"
	)

	local remote = Get("RemoteEvent", name) :: RemoteEvent
	rateLimit = if rateLimit ~= nil then rateLimit else Channel.DefaultRateLimit

	Log("Connected:", name)

	if IsServer then
		return remote.OnServerEvent:Connect(function(player, ...)
			if not CheckRateLimit(player, "RemoteEvent\1" .. name, rateLimit :: number) then
				return
			end

			local success, err = pcall(callback, player, ...)

			if not success then
				WarnRemoteThrottled(
					player,
					"RemoteEvent\1" .. name .. "\1HANDLER_ERROR",
					"Handler error for",
					name,
					"from",
					player.Name,
					":",
					err
				)
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
	assert(
		rateLimit == nil or (type(rateLimit) == "number" and rateLimit >= 0),
		"Channel.SetFunction: rateLimit must be non-negative"
	)

	local remote = Get("RemoteFunction", name) :: RemoteFunction
	rateLimit = if rateLimit ~= nil then rateLimit else Channel.DefaultInvokeRateLimit

	Log("Set function:", name)

	if IsServer then
		remote.OnServerInvoke = function(player, ...)
			if not CheckRateLimit(player, "RemoteFunction\1" .. name, rateLimit :: number) then
				return nil
			end

			local results = PackArgs(pcall(callback, player, ...))

			if not results[1] then
				WarnRemoteThrottled(
					player,
					"RemoteFunction\1" .. name .. "\1HANDLER_ERROR",
					"Function error for",
					name,
					"from",
					player.Name,
					":",
					results[2]
				)
				return nil
			end

			return UnpackArgs(SliceArgs(results, 2))
		end
	else
		remote.OnClientInvoke = function(...)
			local results = PackArgs(pcall(callback, ...))

			if not results[1] then
				Warn("Function error for", name, ":", results[2])
				return nil
			end

			return UnpackArgs(SliceArgs(results, 2))
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
	local args = PackArgs(...)

	Log("InvokeClient:", name, player.Name)

	local thread = coroutine.running()
	local settled = false

	task.spawn(function()
		local results = PackArgs(pcall(function()
			return remote:InvokeClient(player, UnpackArgs(args))
		end))

		if settled then
			return
		end

		settled = true
		task.spawn(thread, results)
	end)

	task.delay(Channel.InvokeClientTimeout, function()
		if settled then
			return
		end

		settled = true
		task.spawn(
			thread,
			PackArgs(
				false,
				("InvokeClient '%s' to %s timed out after %.3gs"):format(name, player.Name, Channel.InvokeClientTimeout)
			)
		)
	end)

	local results = coroutine.yield()

	if not results[1] then
		Warn("InvokeClient failed:", name, player.Name, results[2])
		return nil
	end

	return UnpackArgs(SliceArgs(results, 2))
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

local SIGNAL_MARKER = newproxy(true);
(getmetatable(SIGNAL_MARKER) :: any).__tostring = function()
	return "SIGNAL_MARKER"
end

local UNRELIABLE_SIGNAL_MARKER = newproxy(true);
(getmetatable(UNRELIABLE_SIGNAL_MARKER) :: any).__tostring = function()
	return "UNRELIABLE_SIGNAL_MARKER"
end

local PROPERTY_MARKER = newproxy(true);
(getmetatable(PROPERTY_MARKER) :: any).__tostring = function()
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
	outbound: MiddlewareList?,
	serviceName: string?,
	policy: RemotePolicy?,
	maxPayloadBytes: number?
)
	return setmetatable({
		_remote = remote,
		_bucketKey = bucketKey,
		_rateLimit = if rateLimit ~= nil then rateLimit else Channel.DefaultRateLimit,
		_inbound = inbound,
		_outbound = outbound,
		_serviceName = serviceName,
		_policy = policy,
		_maxPayloadBytes = if maxPayloadBytes ~= nil then maxPayloadBytes else Channel.DefaultMaxPayloadBytes,
	}, Signal)
end

-- Server: Signal:Fire(player, ...) fires to exactly one client. Runs Outbound
-- middleware (if any) first; middleware returning false drops the send.
-- Client: Signal:Fire(...) fires to the server (no middleware here - Inbound
-- middleware runs on the receiving end, inside :Connect, below).
function Signal:Fire(...: any)
	if IsServer then
		local player = ...
		assert(
			typeof(player) == "Instance" and player:IsA("Player"),
			"Signal:Fire (server) expects a Player as the first argument"
		)

		local args = PackArgs(...)
		local outArgs = SliceArgs(args, 2)

		if self._outbound and not RunMiddleware(self._outbound, player, outArgs) then
			return
		end

		local ok, err = pcall(function()
			self._remote:FireClient(player, UnpackArgs(outArgs))
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

	local outArgs = PackArgs(...)
	if self._outbound and not RunMiddleware(self._outbound, nil, outArgs) then
		return
	end

	self._remote:FireAllClients(UnpackArgs(outArgs))
end

function Signal:FireExcept(exceptPlayer: Player, ...: any)
	assert(IsServer, "Signal:FireExcept is server-only")

	local outArgs = PackArgs(...)
	if self._outbound and not RunMiddleware(self._outbound, nil, outArgs) then
		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= exceptPlayer then
			self._remote:FireClient(player, UnpackArgs(outArgs))
		end
	end
end

function Signal:Connect(fn: (...any) -> ())
	assert(type(fn) == "function", "Signal:Connect expects a function")

	if IsServer then
		return (self._remote :: RemoteEvent).OnServerEvent:Connect(function(player, ...)
			if self._serviceName and not ServiceReady[self._serviceName] then
				return
			end
			if self._bucketKey and not CheckRateLimit(player, self._bucketKey, self._rateLimit) then
				return
			end

			local inArgs = PackArgs(...)
			local valid, validationCode, validationMessage =
				ValidateInbound(player, inArgs, self._policy, self._maxPayloadBytes)
			if not valid then
				WarnRemoteThrottled(
					player,
					(self._bucketKey or self._remote.Name) .. "\1" .. (validationCode or "INVALID_PAYLOAD"),
					"Rejected signal payload:",
					self._serviceName or "?",
					self._remote.Name,
					validationCode,
					validationMessage
				)
				return
			end
			if self._inbound and not RunMiddleware(self._inbound, player, inArgs) then
				return
			end

			local ok, err = pcall(fn, player, UnpackArgs(inArgs))
			if not ok then
				WarnRemoteThrottled(
					player,
					(self._bucketKey or self._remote.Name) .. "\1HANDLER_ERROR",
					"Signal handler error:",
					err
				)
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

local NIL_OVERRIDE = newproxy()

local function DecodeOverride(value: any): any
	if value == NIL_OVERRIDE then
		return nil
	end
	return value
end

function Property.new(
	remoteEvent: RemoteEvent,
	remoteFunction: RemoteFunction,
	initialValue: any?,
	outbound: MiddlewareList?,
	serviceName: string?
)
	local self = setmetatable({
		_remoteEvent = remoteEvent,
		_remoteFunction = remoteFunction,
		_value = initialValue,
		_overrides = {} :: { [Player]: any }, -- server-only: per-player value overrides
		_observers = {} :: { (any) -> () },
		_playerRemovingConnection = nil :: RBXScriptConnection?,
		_remoteEventConnection = nil :: RBXScriptConnection?,
		_revision = 0,
		_outbound = outbound,
		_serviceName = serviceName,
	}, Property)

	if IsServer then
		self._remoteFunction.OnServerInvoke = function(player)
			if self._serviceName and not ServiceReady[self._serviceName] then
				return nil, self._revision
			end
			local override = self._overrides[player]
			if override ~= nil then
				return DecodeOverride(override), self._revision
			end
			return self._value, self._revision
		end

		self._playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
			self._overrides[player] = nil
		end)
	else
		self._remoteEventConnection = self._remoteEvent.OnClientEvent:Connect(function(newValue, revision)
			if type(revision) == "number" and revision < self._revision then
				return
			end
			if type(revision) == "number" then
				self._revision = revision
			end
			self._value = newValue
			for _, fn in ipairs(self._observers) do
				task.spawn(fn, newValue)
			end
		end)

		local ok, value, revision = pcall(function()
			return self._remoteFunction:InvokeServer()
		end)

		if not ok then
			error(MakeRemoteError("TRANSPORT_ERROR", tostring(value), serviceName or "?", remoteFunction.Name), 0)
		end
		if type(revision) ~= "number" or revision >= self._revision then
			self._value = value
			if type(revision) == "number" then
				self._revision = revision
			end
		end
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

	local outArgs = PackArgs(value)
	if self._outbound and not RunMiddleware(self._outbound, nil, outArgs) then
		return
	end
	value = outArgs[1]

	self._value = value
	self._revision += 1

	for _, player in ipairs(Players:GetPlayers()) do
		if self._overrides[player] == nil then
			self._remoteEvent:FireClient(player, value, self._revision)
		end
	end
end

-- Sets a value visible only to `player`, overriding the shared default
-- until :ClearFor(player) is called or the player leaves. Runs Outbound
-- middleware (if any) first, the same way :Set does.
function Property:SetFor(player: Player, value: any)
	assert(IsServer, "Property:SetFor is server-only")
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Property:SetFor expects a Player")

	local outArgs = PackArgs(value)
	if self._outbound and not RunMiddleware(self._outbound, player, outArgs) then
		return
	end
	value = outArgs[1]

	self._overrides[player] = if value == nil then NIL_OVERRIDE else value
	self._revision += 1
	self._remoteEvent:FireClient(player, value, self._revision)
end

function Property:GetFor(player: Player): any
	assert(IsServer, "Property:GetFor is server-only")
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Property:GetFor expects a Player")

	local override = self._overrides[player]
	if override ~= nil then
		return DecodeOverride(override)
	end
	return self._value
end

-- Removes `player`'s override, reverting them back to the shared default.
function Property:ClearFor(player: Player)
	assert(IsServer, "Property:ClearFor is server-only")
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Property:ClearFor expects a Player")

	if self._overrides[player] == nil then
		return
	end

	self._overrides[player] = nil
	self._revision += 1
	self._remoteEvent:FireClient(player, self._value, self._revision)
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
	if self._remoteEventConnection then
		self._remoteEventConnection:Disconnect()
		self._remoteEventConnection = nil
	end
	table.clear(self._observers)
	table.clear(self._overrides)
end

--------------------------------------------------
-- Service-scoped API: WrapService (server) / BuildClient (client)
--------------------------------------------------

-- Publishes the marker BuildClient waits for. Thread defers this until all
-- lifecycle methods have completed, while direct WrapService callers publish
-- immediately after every Remote has been created.
function Channel.MarkServiceReady(serviceName: string)
	assert(IsServer, "Channel.MarkServiceReady is server-only")
	assert(type(serviceName) == "string", "Channel.MarkServiceReady: serviceName must be a string")

	local servicesFolder = GetOrCreateFolder(Root, "Services")
	local existing = servicesFolder:FindFirstChild(serviceName)
	if existing then
		existing:Destroy()
	end

	local marker = Instance.new("Folder")
	marker.Name = serviceName
	local manifest = ServiceManifests[serviceName] or {}
	marker:SetAttribute("Manifest", HttpService:JSONEncode({ Protocol = RESPONSE_PROTOCOL, Remotes = manifest }))
	for _, class in ipairs(RemoteClasses) do
		local classFolder = Root:FindFirstChild(class)
		local namespace = classFolder and classFolder:FindFirstChild(serviceName)
		marker:SetAttribute(class .. "Count", if namespace then #namespace:GetChildren() else 0)
	end
	marker.Parent = servicesFolder
	ServiceReady[serviceName] = true
end

function Channel.GetServiceManifest(serviceName: string): { { Name: string, Kind: string, Class: string } }
	assert(type(serviceName) == "string", "Channel.GetServiceManifest expects a string")
	local copy = {}
	for index, entry in ipairs(ServiceManifests[serviceName] or {}) do
		copy[index] = table.clone(entry)
	end
	return copy
end

-- Binds a service's `Client` table to real Remote instances. Functions
-- become RemoteFunctions, signal/property markers become Signal/Property
-- objects (mutating the table in place, same as the markers they replace).
function Channel.WrapService(serviceName: string, clientTable: { [any]: any }, opts: WrapOptions?)
	assert(IsServer, "Channel.WrapService is server-only")
	assert(
		type(serviceName) == "string" and #serviceName > 0,
		"Channel.WrapService: serviceName must be a non-empty string"
	)
	assert(type(clientTable) == "table", "Channel.WrapService: clientTable must be a table")
	assert(opts == nil or type(opts) == "table", "Channel.WrapService: opts must be a table")

	opts = opts or {}
	local allowedOptions = {
		Middleware = true,
		Policies = true,
		RateLimit = true,
		InvokeRateLimit = true,
		MaxPayloadBytes = true,
		DeferReady = true,
	}
	for optionName in pairs(opts :: any) do
		assert(
			allowedOptions[optionName] == true,
			("Channel.WrapService: unknown option '%s'"):format(tostring(optionName))
		)
	end
	local middleware = opts.Middleware or {}
	assert(type(middleware) == "table", "Channel.WrapService: Middleware must be a table")
	for middlewareOption in pairs(middleware :: any) do
		assert(
			middlewareOption == "Inbound" or middlewareOption == "Outbound",
			("Channel.WrapService: Middleware has unknown option '%s'"):format(tostring(middlewareOption))
		)
	end
	local function validateMiddlewareList(label: string, list: any)
		if list == nil then
			return
		end
		assert(type(list) == "table", ("Channel.WrapService: Middleware.%s must be a table"):format(label))
		local count = 0
		for index, middlewareFn in pairs(list) do
			assert(
				type(index) == "number" and index % 1 == 0 and index >= 1,
				("Channel.WrapService: Middleware.%s must be an array"):format(label)
			)
			assert(
				type(middlewareFn) == "function",
				("Channel.WrapService: Middleware.%s[%d] must be a function"):format(label, index)
			)
			count += 1
		end
		assert(count == #list, ("Channel.WrapService: Middleware.%s must be a dense array"):format(label))
	end
	validateMiddlewareList("Inbound", middleware.Inbound)
	validateMiddlewareList("Outbound", middleware.Outbound)
	local inbound = middleware.Inbound
	local outbound = middleware.Outbound
	local rateLimit = if opts.RateLimit ~= nil then opts.RateLimit else Channel.DefaultRateLimit
	local invokeRateLimit = if opts.InvokeRateLimit ~= nil then opts.InvokeRateLimit else Channel.DefaultInvokeRateLimit
	local maxPayloadBytes = if opts.MaxPayloadBytes ~= nil then opts.MaxPayloadBytes else Channel.DefaultMaxPayloadBytes
	local policies = opts.Policies or {}
	assert(type(rateLimit) == "number" and rateLimit >= 0, "Channel.WrapService: RateLimit must be non-negative")
	assert(
		type(invokeRateLimit) == "number" and invokeRateLimit >= 0,
		"Channel.WrapService: InvokeRateLimit must be non-negative"
	)
	assert(
		type(maxPayloadBytes) == "number" and maxPayloadBytes >= 0 and maxPayloadBytes % 1 == 0,
		"Channel.WrapService: MaxPayloadBytes must be a non-negative integer"
	)
	assert(type(policies) == "table", "Channel.WrapService: Policies must be a table")
	assert(
		opts.DeferReady == nil or type(opts.DeferReady) == "boolean",
		"Channel.WrapService: DeferReady must be a boolean"
	)

	local keys = {}
	for key in pairs(clientTable) do
		if type(key) == "string" and key ~= "Server" then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	for policyName in pairs(policies) do
		assert(
			type(policyName) == "string" and table.find(keys, policyName) ~= nil,
			("Channel.WrapService: policy references unknown Client member '%s'"):format(tostring(policyName))
		)
	end
	for _, key in ipairs(keys) do
		local value = clientTable[key]
		local isProperty = type(value) == "table" and value[1] == PROPERTY_MARKER
		assert(
			type(value) == "function" or value == SIGNAL_MARKER or value == UNRELIABLE_SIGNAL_MARKER or isProperty,
			("Channel.WrapService: Client member '%s' must be a function, Signal, or Property"):format(key)
		)
		local policy = policies[key]
		if policy ~= nil then
			assert(not isProperty, ("Channel.WrapService: policies are not supported for Property '%s'"):format(key))
			assert(type(policy) == "table", ("Channel.WrapService: policy for '%s' must be a table"):format(key))
			local allowedPolicyOptions =
				{ Arguments = true, AllowExtraArguments = true, MaxPayloadBytes = true, RateLimit = true }
			for policyOption in pairs(policy :: any) do
				assert(
					allowedPolicyOptions[policyOption] == true,
					("Channel.WrapService: policy for '%s' has unknown option '%s'"):format(key, tostring(policyOption))
				)
			end
			if policy.MaxPayloadBytes ~= nil then
				assert(
					type(policy.MaxPayloadBytes) == "number"
						and policy.MaxPayloadBytes >= 0
						and policy.MaxPayloadBytes % 1 == 0,
					("Channel.WrapService: policy MaxPayloadBytes for '%s' must be a non-negative integer"):format(key)
				)
			end
			if policy.RateLimit ~= nil then
				assert(
					type(policy.RateLimit) == "number" and policy.RateLimit >= 0,
					("Channel.WrapService: policy RateLimit for '%s' must be non-negative"):format(key)
				)
			end
			if policy.Arguments ~= nil then
				assert(
					type(policy.Arguments) == "table",
					("Channel.WrapService: policy Arguments for '%s' must be a table"):format(key)
				)
				local validatorCount = 0
				for validatorIndex, validator in pairs(policy.Arguments) do
					assert(
						type(validatorIndex) == "number" and validatorIndex % 1 == 0 and validatorIndex >= 1,
						("Channel.WrapService: policy Arguments for '%s' must be an array"):format(key)
					)
					assert(
						type(validator) == "function",
						("Channel.WrapService: validator %d for '%s' must be a function"):format(validatorIndex, key)
					)
					validatorCount += 1
				end
				assert(
					validatorCount == #policy.Arguments,
					("Channel.WrapService: policy Arguments for '%s' must be a dense array"):format(key)
				)
			end
			if policy.AllowExtraArguments ~= nil then
				assert(
					type(policy.AllowExtraArguments) == "boolean",
					("Channel.WrapService: policy AllowExtraArguments for '%s' must be a boolean"):format(key)
				)
			end
		end
	end

	if ServiceObjects[serviceName] ~= nil then
		Channel.Destroy(serviceName)
	end
	local servicesFolder = GetOrCreateFolder(Root, "Services")
	local staleMarker = servicesFolder:FindFirstChild(serviceName)
	if staleMarker then
		staleMarker:Destroy()
	end

	ServiceObjects[serviceName] = {}
	ServiceReady[serviceName] = false
	ServiceManifests[serviceName] = {}

	for _, key in ipairs(keys) do
		local value = clientTable[key]
		local policy = policies[key]

		if type(value) == "function" then
			local remote = Get("RemoteFunction", key, serviceName) :: RemoteFunction
			remote:SetAttribute("ThreadKind", "Method")

			local bucketKey = serviceName .. "." .. key
			local methodRateLimit = if policy and policy.RateLimit ~= nil then policy.RateLimit else invokeRateLimit
			table.insert(ServiceManifests[serviceName], { Name = key, Kind = "Method", Class = "RemoteFunction" })

			remote.OnServerInvoke = function(player, ...)
				if not ServiceReady[serviceName] then
					return ErrorResponse(MakeRemoteError("SERVICE_NOT_READY", "Service is not ready", serviceName, key))
				end
				if not CheckRateLimit(player, bucketKey, methodRateLimit) then
					return ErrorResponse(MakeRemoteError("RATE_LIMITED", "Rate limit exceeded", serviceName, key))
				end

				local inArgs = PackArgs(...)
				local valid, validationCode, validationMessage =
					ValidateInbound(player, inArgs, policy, maxPayloadBytes)
				if not valid then
					return ErrorResponse(
						MakeRemoteError(validationCode :: string, validationMessage :: string, serviceName, key)
					)
				end
				if not RunMiddleware(inbound, player, inArgs) then
					return ErrorResponse(
						MakeRemoteError(
							"MIDDLEWARE_REJECTED",
							"Inbound middleware rejected the request",
							serviceName,
							key
						)
					)
				end

				local results = PackArgs(pcall(value, clientTable, player, UnpackArgs(inArgs)))
				local success = results[1]

				if not success then
					WarnRemoteThrottled(
						player,
						bucketKey .. "\1HANDLER_ERROR",
						"Client method error:",
						serviceName,
						key,
						"from",
						if player then player.Name else "?",
						":",
						results[2]
					)
					return ErrorResponse(
						MakeRemoteError(
							"HANDLER_ERROR",
							"Server method failed",
							serviceName,
							key,
							if Channel.Debug then tostring(results[2]) else nil
						)
					)
				end

				local outArgs = SliceArgs(results, 2)
				if not RunMiddleware(outbound, player, outArgs) then
					return ErrorResponse(
						MakeRemoteError(
							"OUTBOUND_REJECTED",
							"Outbound middleware rejected the response",
							serviceName,
							key
						)
					)
				end
				local outputValid, outputCode, outputMessage = ValidateInbound(
					player,
					outArgs,
					nil,
					if policy and policy.MaxPayloadBytes ~= nil then policy.MaxPayloadBytes else maxPayloadBytes
				)
				if not outputValid then
					return ErrorResponse(
						MakeRemoteError(
							"RESPONSE_" .. (outputCode :: string),
							outputMessage :: string,
							serviceName,
							key
						)
					)
				end
				return SuccessResponse(outArgs)
			end
		elseif value == SIGNAL_MARKER or value == UNRELIABLE_SIGNAL_MARKER then
			local class = (value == UNRELIABLE_SIGNAL_MARKER) and "UnreliableRemoteEvent" or "RemoteEvent"
			local remote = Get(class, key, serviceName) :: RemoteEvent
			remote:SetAttribute("ThreadKind", "Signal")

			local bucketKey = serviceName .. "." .. key
			local signalRateLimit = if policy and policy.RateLimit ~= nil then policy.RateLimit else rateLimit
			clientTable[key] =
				Signal.new(remote, bucketKey, signalRateLimit, inbound, outbound, serviceName, policy, maxPayloadBytes)
			table.insert(ServiceObjects[serviceName], clientTable[key])
			table.insert(ServiceManifests[serviceName], { Name = key, Kind = "Signal", Class = class })
		elseif type(value) == "table" and value[1] == PROPERTY_MARKER then
			local remoteEvent = Get("RemoteEvent", key, serviceName) :: RemoteEvent
			local remoteFunction = Get("RemoteFunction", key, serviceName) :: RemoteFunction
			remoteEvent:SetAttribute("ThreadKind", "Property")
			remoteFunction:SetAttribute("ThreadKind", "Property")

			clientTable[key] = Property.new(remoteEvent, remoteFunction, value[2], outbound, serviceName)
			table.insert(ServiceObjects[serviceName], clientTable[key])
			table.insert(ServiceManifests[serviceName], { Name = key, Kind = "Property", Class = "Property" })
		else
			error(("Channel.WrapService: Client member '%s' must be a function, Signal, or Property"):format(key), 0)
		end
	end

	if not opts.DeferReady then
		Channel.MarkServiceReady(serviceName)
	end
end

-- Builds a client-side proxy for a service by inspecting the Remote
-- instances the server created via WrapService. Call proxy:Method(...) for
-- methods, proxy.SomeSignal:Connect(fn) for signals, proxy.SomeProp:Get()
-- for properties.
function Channel.BuildClient(serviceName: string, timeout: number?): { [string]: any }
	assert(not IsServer, "Channel.BuildClient is client-only")
	assert(type(serviceName) == "string", "Channel.BuildClient: serviceName must be a string")

	local waitTimeout = if timeout ~= nil then timeout else Channel.WaitTimeout
	assert(type(waitTimeout) == "number" and waitTimeout >= 0, "Channel.BuildClient: timeout must be non-negative")
	local deadline = os.clock() + waitTimeout
	local function remainingTime(): number
		return math.max(deadline - os.clock(), 0)
	end

	-- Wait once on the service ready marker instead of blindly
	-- WaitForChild-ing every Remote class folder - a service that only
	-- exposes Methods, for example, never creates a RemoteEvent folder at
	-- all, and waiting on it would stall for no reason.
	local servicesFolder = Root:FindFirstChild("Services") or Root:WaitForChild("Services", remainingTime())
	if not servicesFolder then
		error(
			("[Channel] No services became ready (waited %.3gs). Make sure the server completed Thread.Start() successfully."):format(
				waitTimeout
			),
			0
		)
	end

	local serviceFolder = servicesFolder:FindFirstChild(serviceName)
		or servicesFolder:WaitForChild(serviceName, remainingTime())
	if not serviceFolder then
		error(
			("[Channel] Service '%s' never became ready (waited %.3gs). Check its name and server startup result."):format(
				serviceName,
				waitTimeout
			),
			0
		)
	end

	local proxy: { [string]: any } = {}
	local pendingProperties: { [string]: { remoteEvent: RemoteEvent?, remoteFunction: RemoteFunction? } } = {}
	local manifestJson = serviceFolder:GetAttribute("Manifest")

	if type(manifestJson) == "string" then
		local decodedOk, decoded = pcall(HttpService.JSONDecode, HttpService, manifestJson)
		if not decodedOk or type(decoded) ~= "table" or type(decoded.Remotes) ~= "table" then
			error(("[Channel] Service '%s' published an invalid manifest"):format(serviceName), 0)
		end

		local function waitForRemote(class: string, remoteName: string): Instance
			local classFolder = Root:FindFirstChild(class) or Root:WaitForChild(class, remainingTime())
			if not classFolder then
				error(("[Channel] Service '%s' manifest references missing %s folder"):format(serviceName, class), 0)
			end
			local namespace = classFolder:FindFirstChild(serviceName)
				or classFolder:WaitForChild(serviceName, remainingTime())
			if not namespace then
				error(("[Channel] Service '%s' manifest references missing %s namespace"):format(serviceName, class), 0)
			end
			local remote = namespace:FindFirstChild(remoteName) or namespace:WaitForChild(remoteName, remainingTime())
			if not remote or not remote:IsA(class) then
				error(
					("[Channel] Service '%s' manifest references missing %s '%s'"):format(
						serviceName,
						class,
						remoteName
					),
					0
				)
			end
			Cache[class .. "\1" .. serviceName .. "\1" .. remoteName] = remote
			return remote
		end

		for _, entry in ipairs(decoded.Remotes) do
			if type(entry) ~= "table" or type(entry.Name) ~= "string" or type(entry.Kind) ~= "string" then
				error(("[Channel] Service '%s' manifest contains an invalid entry"):format(serviceName), 0)
			end
			local key = entry.Name
			if entry.Kind == "Method" and entry.Class == "RemoteFunction" then
				local remote = waitForRemote("RemoteFunction", key) :: RemoteFunction
				proxy[key] = function(_self, ...: any): any
					local invocation = PackArgs(pcall(function(...)
						return remote:InvokeServer(...)
					end, ...))
					if not invocation[1] then
						error(MakeRemoteError("TRANSPORT_ERROR", tostring(invocation[2]), serviceName, key), 0)
					end
					return Channel.DecodeResponse(invocation[2])
				end
			elseif
				entry.Kind == "Signal" and (entry.Class == "RemoteEvent" or entry.Class == "UnreliableRemoteEvent")
			then
				proxy[key] = Signal.new(waitForRemote(entry.Class, key) :: any, serviceName .. "." .. key)
			elseif entry.Kind == "Property" then
				local remoteFunction = waitForRemote("RemoteFunction", key) :: RemoteFunction
				local remoteEvent = waitForRemote("RemoteEvent", key) :: RemoteEvent
				proxy[key] = Property.new(remoteEvent, remoteFunction)
			else
				error(("[Channel] Service '%s' manifest has unsupported entry '%s'"):format(serviceName, key), 0)
			end
		end

		return proxy
	end

	-- The service is confirmed ready at this point, so a missing class
	-- folder here just means "this service doesn't use that Remote class" -
	-- no need to wait any further.
	local function scan(class: string)
		local expectedCount = serviceFolder:GetAttribute(class .. "Count")
		if expectedCount == 0 then
			return
		end

		local classFolder = Root:FindFirstChild(class)
		if not classFolder and type(expectedCount) == "number" then
			classFolder = Root:WaitForChild(class, remainingTime())
		end
		if not classFolder then
			if type(expectedCount) == "number" then
				error(("[Channel] Service '%s' is ready but its %s container is missing"):format(serviceName, class), 0)
			end
			return
		end

		local nsFolder = classFolder:FindFirstChild(serviceName)
		if not nsFolder and type(expectedCount) == "number" then
			nsFolder = classFolder:WaitForChild(serviceName, remainingTime())
		end
		if not nsFolder then
			if type(expectedCount) == "number" then
				error(("[Channel] Service '%s' is ready but its %s namespace is missing"):format(serviceName, class), 0)
			end
			return
		end

		if type(expectedCount) == "number" then
			while #nsFolder:GetChildren() < expectedCount and remainingTime() > 0 do
				task.wait()
			end
			if #nsFolder:GetChildren() < expectedCount then
				error(
					("[Channel] Service '%s' Remote manifest did not finish replicating within %.3gs"):format(
						serviceName,
						waitTimeout
					),
					0
				)
			end
		end

		for _, obj in ipairs(nsFolder:GetChildren()) do
			local kind = obj:GetAttribute("ThreadKind")
			local key = obj.Name
			local cacheKey = class .. "\1" .. serviceName .. "\1" .. key
			Cache[cacheKey] = obj

			if kind == "Method" then
				proxy[key] = function(_self, ...: any): any
					local response = (obj :: RemoteFunction):InvokeServer(...)
					return Channel.DecodeResponse(response)
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

	local objects = ServiceObjects[serviceName]
	if objects then
		for _, object in ipairs(objects) do
			local ok, err = pcall(function()
				object:Destroy()
			end)
			if not ok then
				Warn("Failed to destroy service object:", serviceName, err)
			end
		end
		ServiceObjects[serviceName] = nil
	end
	ServiceReady[serviceName] = nil
	ServiceManifests[serviceName] = nil

	for _, class in ipairs(RemoteClasses) do
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

	for key in pairs(Cache) do
		for _, class in ipairs(RemoteClasses) do
			local prefix = class .. "\1" .. serviceName .. "\1"
			if key:sub(1, #prefix) == prefix then
				Cache[key] = nil
				break
			end
		end
	end
	local bucketPrefix = serviceName .. "."
	for player, buckets in pairs(RateBuckets) do
		for key in pairs(buckets) do
			if key:sub(1, #bucketPrefix) == bucketPrefix then
				buckets[key] = nil
			end
		end
		local warnings = WarningTimes[player]
		if warnings then
			for key in pairs(warnings) do
				if key:sub(1, #bucketPrefix) == bucketPrefix then
					warnings[key] = nil
				end
			end
		end
	end

	Log("Destroyed service remotes:", serviceName)
end

return Channel
