--!strict
--[[
	Test suite for Thread / Channel / Promise.

	No external test framework (no TestEZ, no Wally) - built on TestRunner.luau,
	which is nothing but pcall + assert. Run this from a server-side context in
	Roblox Studio: either paste the two lines below into the Command Bar while
	a Play/Run session is active, or drop a throwaway Script under
	ServerScriptService that requires this module, then delete the script again.

		require(game:GetService("ServerScriptService").Tests["Thread.spec"])

	Adjust the path to wherever you actually placed the Thread/ and Tests/
	folders in your Rojo/Studio hierarchy.
]]

local Packages = game:GetService("ReplicatedStorage"):WaitForChild("Packages")

local Promise = require(Packages.Promise)
local Channel = require(Packages.Channel)
local ThreadModuleScript = Packages.Thread :: ModuleScript

local Signal = require(Packages.Util.Signal)
local Trove = require(Packages.Util.Trove)
local TableUtil = require(Packages.Util.TableUtil)
local Option = require(Packages.Util.Option)
local EnumList = require(Packages.Util.EnumList)
local TimerUtil = require(Packages.Util.TimerUtil)

local TestRunner = require(script.Parent.TestRunner)

-- Thread is a singleton module (keeps `_Started` state). To test dependency
-- ordering / start-failure behaviour in isolation, clone the ModuleScript so
-- each test gets its own fresh Thread instance. Channel/Promise are fine to share
-- since they don't carry a one-shot "already started" flag.
local function FreshThread()
	local clone = ThreadModuleScript:Clone()
	clone.Parent = ThreadModuleScript.Parent
	local thread = require(clone) :: any
	return thread, clone
end

TestRunner.Test("Thread exposes the generated typed client facade", function()
	local thread = require(ThreadModuleScript)
	assert(type(thread.Clients) == "table", "Thread.Clients must expose the generated client builders")
end)

TestRunner.Test("Thread rejects Client tables that diverge from the generated manifest", function()
	local packageClone = Packages:Clone()
	packageClone.Name = "ManifestMismatchPackages"
	packageClone.Parent = game:GetService("ReplicatedStorage")

	local generated = packageClone.Generated
	generated.ServiceManifest:Destroy()
	local manifestFixture = script.Parent.Fixtures.Manifest.GeneratedServiceManifest:Clone()
	manifestFixture.Name = "ServiceManifest"
	manifestFixture.Parent = generated

	local thread = require(packageClone.Thread) :: any
	thread.CreateService({
		Name = "ManifestService",
		Client = {
			Wrong = function() end,
		},
	})

	local started, startError = pcall(function()
		thread.Start():await()
	end)
	assert(not started, "startup accepted a Client table that contradicted its generated manifest")
	assert(
		string.find(tostring(startError), "Generated manifest mismatch", 1, true) ~= nil,
		"startup returned the wrong generated manifest error"
	)
	local remoteRoot = game:GetService("ReplicatedStorage").ThreadChannel.RemoteFunction
	assert(remoteRoot:FindFirstChild("ManifestService") == nil, "manifest failure left stale service remotes")

	packageClone:Destroy()
end)

--------------------------------------------------
-- Promise
--------------------------------------------------

TestRunner.Test("Promise resolves and awaits", function()
	local p = Promise.new(function(resolve)
		resolve(42)
	end)
	assert(p:await() == 42, "expected 42")
end)

TestRunner.Test("Promise rejects and catch recovers", function()
	local p = Promise.reject("boom"):catch(function(err)
		return "recovered:" .. err
	end)
	assert(p:await() == "recovered:boom", "catch did not recover")
end)

TestRunner.Test("Promise.all waits for every promise", function()
	local results = Promise.all({
		Promise.resolve(1),
		Promise.resolve(2),
		Promise.resolve(3),
	}):await()
	assert(#results == 3 and results[1] == 1 and results[3] == 3, "Promise.all result mismatch")
end)

TestRunner.Test("Promise.allSettled never rejects", function()
	local results = Promise.allSettled({
		Promise.resolve("ok"),
		Promise.reject("fail"),
	}):await()
	assert(results[1].Status == "Resolved" and results[1].Value == "ok", "first entry should resolve")
	assert(results[2].Status == "Rejected" and results[2].Error == "fail", "second entry should reject")
end)

TestRunner.Test("Promise collections preserve nil values", function()
	local allResults = Promise.all({ Promise.resolve(nil), Promise.resolve("value") }):await()
	assert(allResults.n == 2 and allResults[1] == nil and allResults[2] == "value", "Promise.all lost a nil value")

	local someResults = Promise.some({ Promise.resolve(nil) }, 1):await()
	assert(someResults.n == 1 and someResults[1] == nil, "Promise.some lost a nil value")
end)

TestRunner.Test("Promise releases callbacks after settling", function()
	local promise = Promise.resolve("done") :: any
	assert(promise:await() == "done", "expected promise to resolve")
	assert(#promise._resolveQueue == 0 and #promise._rejectQueue == 0, "settled promise retained callbacks")
end)

TestRunner.Test("Promise rejects self-resolution", function()
	local promise: any
	promise = Promise.new(function(resolve)
		task.delay(0, function()
			resolve(promise)
		end)
	end)

	local ok = pcall(function()
		promise:await()
	end)
	assert(not ok, "a promise resolving with itself must reject")
end)

TestRunner.Test("Promise locks settlement while adopting another Promise", function()
	local adoptedResolve: any = nil
	local adopted = Promise.new(function(resolve)
		adoptedResolve = resolve
	end)
	local promise = Promise.new(function(resolve, reject)
		resolve(adopted)
		reject("must be ignored")
		resolve("also ignored")
	end)
	task.wait()
	adoptedResolve("adopted value")
	assert(promise:await() == "adopted value", "a later settlement beat the adopted Promise")
end)

TestRunner.Test("Promise cancellation runs cleanup and uses a distinct state", function()
	local cleaned = false
	local promise = Promise.new(function(resolve, _reject, onCancel)
		onCancel(function()
			cleaned = true
			resolve("must not resolve")
		end)
	end)
	task.wait()
	assert(promise:cancel("test cancellation"), "pending promise should cancel")
	assert(cleaned and promise:getState() == "Cancelled", "cancellation did not clean up or set its state")
	local ok, err = pcall(function()
		promise:await()
	end)
	assert(not ok and Promise.isCancelledError(err), "cancelled promise did not raise a cancellation error")
end)

TestRunner.Test("Promise reports unhandled rejections", function()
	local reported: any = nil
	Promise.setUnhandledRejectionHandler(function(err)
		reported = err
	end)
	Promise.reject("unhandled-on-purpose")
	task.wait()
	task.wait()
	Promise.setUnhandledRejectionHandler(nil)
	assert(reported == "unhandled-on-purpose", "unhandled rejection was not reported")
end)

--------------------------------------------------
-- Thread: basic registry behaviour
--------------------------------------------------

TestRunner.Test("Thread.CreateService rejects duplicate names", function()
	local thread = FreshThread()
	thread.CreateService({ Name = "Dup" })

	local ok = pcall(function()
		thread.CreateService({ Name = "Dup" })
	end)

	assert(not ok, "expected duplicate registration to error")
end)

TestRunner.Test("Thread.GetService throws for unknown service", function()
	local thread = FreshThread()
	local ok = pcall(function()
		thread.GetService("DoesNotExist")
	end)
	assert(not ok, "expected missing service lookup to error")
end)

TestRunner.Test("Thread.Unregister removes a pending service", function()
	local thread = FreshThread()
	thread.CreateService({ Name = "Temp" })
	assert(thread.Unregister("Temp") == true, "expected Unregister to succeed")
	assert(thread.Unregister("Temp") == false, "second Unregister should be a no-op returning false")
end)

--------------------------------------------------
-- Thread: dependency ordering
--------------------------------------------------

TestRunner.Test("Thread.Start initializes services in dependency order", function()
	local thread = FreshThread()
	local order = {}

	thread.CreateService({
		Name = "C",
		Dependencies = { "B" },
		ThreadInit = function()
			table.insert(order, "C")
		end,
	})

	thread.CreateService({
		Name = "A",
		ThreadInit = function()
			table.insert(order, "A")
		end,
	})

	thread.CreateService({
		Name = "B",
		Dependencies = { "A" },
		ThreadInit = function()
			table.insert(order, "B")
		end,
	})

	thread.Start():await()

	assert(table.concat(order, ",") == "A,B,C", "expected init order A,B,C, got " .. table.concat(order, ","))
end)

TestRunner.Test("Thread.Start rejects (without hard-erroring) on circular dependencies", function()
	local thread = FreshThread()

	thread.CreateService({ Name = "X", Dependencies = { "Y" } })
	thread.CreateService({ Name = "Y", Dependencies = { "X" } })

	-- HaltOnCriticalFailure defaults to false, so Start() itself must not throw.
	local startOk = pcall(function()
		thread.Start():catch(function() end)
	end)
	assert(startOk, "Thread.Start() should not hard-error by default")

	local rejected = false
	thread
		.OnStart()
		:catch(function()
			rejected = true
		end)
		:await()

	assert(rejected, "expected the start Promise to reject on a circular dependency")
end)

TestRunner.Test("Thread rejects late registration and malformed service definitions", function()
	local malformed = FreshThread()
	local sparseOk = pcall(function()
		malformed.CreateService({ Name = "Sparse", Dependencies = { [2] = "Missing" } :: any })
	end)
	assert(not sparseOk, "sparse Dependencies must be rejected")
	local lifecycleOk = pcall(function()
		malformed.CreateService({ Name = "BadLifecycle", ThreadStart = true :: any })
	end)
	assert(not lifecycleOk, "non-function lifecycle hooks must be rejected")

	local thread = FreshThread()
	thread.CreateService({ Name = "Existing" })
	thread.Start():await()
	local lateOk = pcall(function()
		thread.CreateService({ Name = "Late" })
	end)
	assert(not lateOk, "services created after Start would never receive lifecycle hooks")
	thread.Stop():await()
end)

TestRunner.Test("Thread awaits async lifecycle hooks and stops in reverse dependency order", function()
	local thread = FreshThread()
	local order = {}
	for index, name in ipairs({ "A", "B", "C" }) do
		thread.CreateService({
			Name = name,
			Dependencies = if index == 1 then nil else { ({ "A", "B" })[index - 1] },
			ThreadInit = function()
				return Promise.delay(0.01):andThen(function()
					table.insert(order, "init-" .. name)
				end)
			end,
			ThreadStart = function()
				return Promise.delay(0.01):andThen(function()
					table.insert(order, "start-" .. name)
				end)
			end,
			ThreadStop = function()
				return Promise.delay(0.01):andThen(function()
					table.insert(order, "stop-" .. name)
				end)
			end,
		})
	end

	thread.Start():await()
	thread.Stop():await()
	assert(
		table.concat(order, ",") == "init-A,init-B,init-C,start-A,start-B,start-C,stop-C,stop-B,stop-A",
		"async lifecycle order was incorrect: " .. table.concat(order, ",")
	)
end)

TestRunner.Test("Cancelling a lifecycle observer does not cancel Thread startup", function()
	local thread = FreshThread()
	local started = false
	thread.CreateService({
		Name = "CancellationSafe",
		ThreadStart = function()
			return Promise.delay(0.01):andThen(function()
				started = true
			end)
		end,
	})

	local observer = thread.Start()
	observer:cancel("caller no longer cares")
	thread.OnStart():await()
	assert(started, "cancelling a returned observer corrupted internal startup")
	thread.Stop():await()
end)

TestRunner.Test("Thread skips failed services and their dependents", function()
	local thread = FreshThread()
	local failedStartRan = false
	local dependentInitRan = false
	local independentStartRan = false

	thread.CreateService({
		Name = "Failed",
		ThreadInit = function()
			error("expected init failure")
		end,
		ThreadStart = function()
			failedStartRan = true
		end,
	})

	thread.CreateService({
		Name = "Dependent",
		Dependencies = { "Failed" },
		ThreadInit = function()
			dependentInitRan = true
		end,
	})

	thread.CreateService({
		Name = "Independent",
		ThreadStart = function()
			independentStartRan = true
		end,
	})

	thread.Start():await()
	assert(not failedStartRan, "a service that failed ThreadInit must not run ThreadStart")
	assert(not dependentInitRan, "a dependent of a failed service must be skipped")
	assert(independentStartRan, "an independent service should still start")
end)

TestRunner.Test("Thread cleans up a service whose ThreadStart fails", function()
	local thread = FreshThread()
	local stopped = false
	thread.CreateService({
		Name = "FailsDuringStart",
		ThreadStart = function()
			error("expected start failure")
		end,
		ThreadStop = function()
			stopped = true
		end,
	})

	thread.Start():await()
	thread.Stop():await()
	assert(stopped, "ThreadStop must clean up a service after a failed ThreadStart")
end)

TestRunner.Test("Thread stops immediately after a critical lifecycle failure", function()
	local thread = FreshThread()
	local dependentRan = false

	thread.CreateService({
		Name = "Critical",
		Critical = true,
		ThreadInit = function()
			error("expected critical failure")
		end,
	})

	thread.CreateService({
		Name = "AfterCritical",
		Dependencies = { "Critical" },
		ThreadInit = function()
			dependentRan = true
		end,
	})

	thread
		.Start()
		:catch(function()
			return nil
		end)
		:await()
	assert(not dependentRan, "services after a critical failure must not run")
end)

TestRunner.Test("Thread publishes Client services only after lifecycle completion", function()
	local thread = FreshThread()
	local serviceName = "SpecService_Readiness"
	local function markerExists(): boolean
		local servicesFolder = game:GetService("ReplicatedStorage").ThreadChannel:FindFirstChild("Services")
		return servicesFolder ~= nil and servicesFolder:FindFirstChild(serviceName) ~= nil
	end

	thread.CreateService({
		Name = serviceName,
		Client = {
			Ping = function()
				return "pong"
			end,
		},
		ThreadInit = function()
			assert(not markerExists(), "service became ready during ThreadInit")
		end,
		ThreadStart = function()
			assert(not markerExists(), "service became ready during ThreadStart")
		end,
	})

	thread.Start():await()
	local servicesFolder = game:GetService("ReplicatedStorage").ThreadChannel:FindFirstChild("Services")
	local marker = servicesFolder and servicesFolder:FindFirstChild(serviceName)
	assert(marker ~= nil, "service did not become ready after startup")
	assert(marker:GetAttribute("RemoteFunctionCount") == 1, "ready marker has the wrong Remote manifest")
	assert(type(marker:GetAttribute("Manifest")) == "string", "ready marker did not publish a service manifest")
	Channel.Destroy(serviceName)
end)

--------------------------------------------------
-- Thread: Register()
--------------------------------------------------

TestRunner.Test("Thread.Register loads ModuleScripts and reports results", function()
	local thread = FreshThread()

	local folder = script.Parent.Fixtures:Clone()
	folder.Name = "TestServices"
	folder.Parent = script.Parent

	local results = thread.Register(folder)

	assert(#results == 3, "expected 3 results")

	local byName = {}
	for _, r in ipairs(results) do
		byName[r.Module.Name] = r
	end

	assert(byName.GoodModule.Success == true, "GoodModule should have loaded successfully")
	assert(byName.BadModule.Success == false, "BadModule should have failed to load")
	assert(
		byName.FalseModule.Success == true and byName.FalseModule.Result == false,
		"successful false result was lost"
	)

	folder:Destroy()
end)

--------------------------------------------------
-- Channel: service-scoped Signals & Properties
--------------------------------------------------

TestRunner.Test("Channel.WrapService creates a Method RemoteFunction", function()
	local serviceName = "SpecService_Method"
	local client = {
		Ping = function(_self, _player)
			return "pong"
		end,
	}

	Channel.WrapService(serviceName, client)

	local remote = game:GetService("ReplicatedStorage").ThreadChannel.RemoteFunction:FindFirstChild(serviceName)
	assert(remote ~= nil, "expected namespace folder to exist")

	local pingRemote = remote:FindFirstChild("Ping")
	assert(pingRemote ~= nil, "expected Ping RemoteFunction to exist")
	assert(pingRemote:GetAttribute("ThreadKind") == "Method", "expected ThreadKind attribute to be Method")

	Channel.Destroy(serviceName)
end)

TestRunner.Test("Channel rejects malformed structured responses", function()
	local ok, err = pcall(Channel.DecodeResponse, {
		ThreadProtocol = 1,
		Ok = true,
		Values = { "not-an-envelope" },
	})
	assert(
		not ok and Channel.IsRemoteError(err) and err.Code == "MALFORMED_RESPONSE",
		"malformed response was accepted"
	)
end)

TestRunner.Test("Channel rejects invalid payload limits and unknown policies", function()
	local fractionalOk = pcall(Channel.WrapService, "SpecService_FractionalLimit", {
		Ping = function() end,
	}, { MaxPayloadBytes = 1.5 })
	assert(not fractionalOk, "fractional payload limits must be rejected")

	local unknownPolicyOk = pcall(Channel.WrapService, "SpecService_UnknownPolicy", {
		Ping = function() end,
	}, {
		Policies = { Typo = {} },
	})
	assert(not unknownPolicyOk, "a policy typo must not be silently ignored")
	Channel.Destroy("SpecService_FractionalLimit")
	Channel.Destroy("SpecService_UnknownPolicy")
end)

TestRunner.Test("Channel built-in validators reject malformed values", function()
	local validInteger = Channel.Validators.Integer(3)
	local invalidInteger = Channel.Validators.Integer(3.5)
	assert(validInteger and not invalidInteger, "Integer validator accepted a fractional value")

	local finite = Channel.Validators.FiniteNumber(10)
	local infinite = Channel.Validators.FiniteNumber(math.huge)
	assert(finite and not infinite, "FiniteNumber validator accepted infinity")

	local shortString = Channel.Validators.StringMaxLength(3)
	assert(shortString("abc") and not shortString("abcd"), "StringMaxLength enforced the wrong byte limit")

	local optionalNumber = Channel.Validators.Optional(Channel.Validators.Number)
	assert(
		optionalNumber(nil) and optionalNumber(2) and not optionalNumber("2"),
		"Optional validator behaved incorrectly"
	)

	local numberArray = Channel.Validators.Array(Channel.Validators.Number, 2)
	assert(numberArray({ 1, 2 }), "Array validator rejected a valid dense array")
	assert(not numberArray({ 1, "2" }), "Array validator accepted an invalid item")
	assert(not numberArray({ [2] = 2 }), "Array validator accepted a sparse array")
	assert(not numberArray({ 1, 2, 3 }), "Array validator ignored its maximum length")
end)

TestRunner.Test("Channel.WrapService turns a Property marker into a working Property", function()
	local serviceName = "SpecService_Property"
	local client = {
		Score = Channel.CreateProperty(0),
	}

	Channel.WrapService(serviceName, client)

	assert(client.Score:Get() == 0, "expected initial value 0")

	client.Score:Set(10)
	assert(client.Score:Get() == 10, "expected value 10 after Set")

	local removingConnection = (client.Score :: any)._playerRemovingConnection
	Channel.Destroy(serviceName)
	assert(removingConnection ~= nil and not removingConnection.Connected, "Property cleanup connection leaked")
end)

TestRunner.Test("Channel.WrapService applies Outbound middleware to Property:Set", function()
	local serviceName = "SpecService_PropertyMiddleware"
	local middlewareRan = false

	local client = {
		Score = Channel.CreateProperty(0),
	}

	Channel.WrapService(serviceName, client, {
		Middleware = {
			Outbound = {
				function(_player, args)
					middlewareRan = true
					args[1] = args[1] * 2 -- double the value on the way out
					return true
				end,
			},
		},
	})

	client.Score:Set(5)

	assert(middlewareRan, "expected Outbound middleware to run")
	assert(client.Score:Get() == 10, "expected middleware to have doubled the value to 10")

	Channel.Destroy(serviceName)
end)

TestRunner.Test("Channel.WrapService Outbound middleware can block a Signal:FireAll", function()
	local serviceName = "SpecService_SignalMiddleware"
	local blocked = false

	local client = {
		Alert = Channel.CreateSignal(),
	}

	Channel.WrapService(serviceName, client, {
		Middleware = {
			Outbound = {
				function(_player, _args)
					blocked = true
					return false -- drop every outgoing Alert
				end,
			},
		},
	})

	-- FireAll should run (and be blocked by) the middleware without erroring,
	-- even with zero players connected in this test session.
	client.Alert:FireAll("test")

	assert(blocked, "expected Outbound middleware to have run and blocked the fire")

	Channel.Destroy(serviceName)
end)

TestRunner.Test("Channel.Destroy removes a service's remotes", function()
	local serviceName = "SpecService_Destroy"
	Channel.WrapService(serviceName, {
		Foo = function() end,
	})

	local before = game:GetService("ReplicatedStorage").ThreadChannel.RemoteFunction:FindFirstChild(serviceName)
	assert(before ~= nil, "expected namespace folder to exist before Destroy")

	Channel.Destroy(serviceName)

	local after = game:GetService("ReplicatedStorage").ThreadChannel.RemoteFunction:FindFirstChild(serviceName)
	assert(after == nil, "expected namespace folder to be gone after Destroy")
end)

TestRunner.Test("Property per-player overrides (skipped without a live Player)", function()
	local players = game:GetService("Players"):GetPlayers()

	if #players == 0 then
		print("[SKIP] no live Players in this session - run during Play/Test mode to exercise this")
		return
	end

	local player = players[1]
	local serviceName = "SpecService_PropertyOverride"
	local client = { Score = Channel.CreateProperty(0) }

	Channel.WrapService(serviceName, client)

	client.Score:Set(5)
	assert(client.Score:GetFor(player) == 5, "expected default value when no override is set")

	client.Score:SetFor(player, 99)
	assert(client.Score:GetFor(player) == 99, "expected the per-player override")
	assert(client.Score:Get() == 5, "the shared default should be unaffected by a per-player override")

	client.Score:ClearFor(player)
	assert(client.Score:GetFor(player) == 5, "expected the override to be cleared back to the default")

	client.Score:SetFor(player, nil)
	assert(client.Score:GetFor(player) == nil, "expected nil to be a valid per-player override")
	client.Score:ClearFor(player)
	assert(client.Score:GetFor(player) == 5, "expected clearing a nil override to restore the default")

	Channel.Destroy(serviceName)
end)

--------------------------------------------------
-- Promise: race / some / retry / timeout / fromEvent
--------------------------------------------------

TestRunner.Test("Promise.race settles with the first promise to finish", function()
	local fast = Promise.delay(0):andThen(function()
		return "fast"
	end)
	local slow = Promise.delay(1):andThen(function()
		return "slow"
	end)

	assert(Promise.race({ slow, fast }):await() == "fast", "expected the faster promise to win the race")
end)

TestRunner.Test("Promise.some resolves once enough promises resolve", function()
	local results = Promise.some({
		Promise.resolve(1),
		Promise.resolve(2),
		Promise.reject("nope"),
	}, 2):await()

	assert(#results == 2, "expected exactly 2 results")
end)

TestRunner.Test("Promise.retry retries until success", function()
	local attempts = 0

	local result = Promise.retry(function()
		attempts += 1
		if attempts < 3 then
			return Promise.reject("not yet")
		end
		return Promise.resolve("done")
	end, 5):await()

	assert(result == "done" and attempts == 3, "expected exactly 3 attempts before success")
end)

TestRunner.Test("Promise.retry handles synchronous errors on later attempts", function()
	local attempts = 0
	local result = Promise.retry(function()
		attempts += 1
		if attempts < 3 then
			error("not yet")
		end
		return Promise.resolve("done")
	end, 3):await()

	assert(result == "done" and attempts == 3, "expected synchronous failures to be retried")
end)

TestRunner.Test("Promise:timeout rejects a promise that settles too slowly", function()
	local slow = Promise.delay(2):andThen(function()
		return "too slow"
	end)

	local ok = pcall(function()
		slow:timeout(0.05):await()
	end)

	assert(not ok, "expected the timeout to reject before the slow promise resolves")
end)

TestRunner.Test("Promise.fromEvent resolves with the next fired value", function()
	local signal = Signal.new()
	local promise = Promise.fromEvent(signal)

	task.delay(0, function()
		signal:Fire("hello")
	end)

	assert(promise:await() == "hello", "expected fromEvent to resolve with the fired value")
	signal:Destroy()
end)

--------------------------------------------------
-- Util: Signal
--------------------------------------------------

TestRunner.Test("Signal fires connected handlers with the given arguments", function()
	local signal = Signal.new()
	local received = nil

	signal:Connect(function(a, b)
		received = a + b
	end)

	signal:Fire(2, 3)
	task.wait()

	assert(received == 5, "expected the handler to receive the fired arguments")
	signal:Destroy()
end)

TestRunner.Test("Signal:Once only fires a single time", function()
	local signal = Signal.new()
	local count = 0

	signal:Once(function()
		count += 1
	end)

	signal:Fire()
	signal:Fire()
	task.wait()

	assert(count == 1, "expected a Once handler to fire exactly once")
	signal:Destroy()
end)

TestRunner.Test("Signal:DisconnectAll stops future fires", function()
	local signal = Signal.new()
	local fired = false

	signal:Connect(function()
		fired = true
	end)
	signal:DisconnectAll()
	signal:Fire()
	task.wait()

	assert(fired == false, "expected no handlers to run after DisconnectAll")
end)

--------------------------------------------------
-- Util: Trove
--------------------------------------------------

TestRunner.Test("Trove cleans up added objects on Destroy", function()
	local trove = Trove.new()
	local cleaned = false

	trove:Add(function()
		cleaned = true
	end)
	trove:Destroy()

	assert(cleaned == true, "expected the tracked function to run on Destroy")
end)

TestRunner.Test("Trove:Remove excludes an object from cleanup", function()
	local trove = Trove.new()
	local cleaned = false
	local fn = function()
		cleaned = true
	end

	trove:Add(fn)
	trove:Remove(fn)
	trove:Clean()

	assert(cleaned == false, "expected a removed object to not be cleaned up")
end)

TestRunner.Test("Trove:Extend cleans up the sub-trove with its parent", function()
	local trove = Trove.new()
	local sub = trove:Extend()
	local cleaned = false

	sub:Add(function()
		cleaned = true
	end)
	trove:Destroy()

	assert(cleaned == true, "expected the sub-trove to be cleaned when the parent trove is destroyed")
end)

TestRunner.Test("Promise.fromEvent rejects and disconnects when its predicate errors", function()
	local signal = Signal.new()
	local promise = Promise.fromEvent(signal, function()
		error("predicate failed")
	end)

	task.delay(0, function()
		signal:Fire("hello")
	end)

	local ok = pcall(function()
		promise:await()
	end)
	assert(not ok, "expected predicate error to reject the promise")
	assert(#signal:GetConnections() == 0, "fromEvent left its connection behind")
	signal:Destroy()
end)

TestRunner.Test("Trove cannot be reused after Destroy", function()
	local trove = Trove.new()
	trove:Destroy()

	local ok = pcall(function()
		trove:Add(function() end)
	end)
	assert(not ok, "expected Add after Destroy to fail")
end)

TestRunner.Test("Trove continues cleanup after a cleanup function errors", function()
	local trove = Trove.new()
	local cleaned = false
	trove:Add(function()
		error("expected cleanup error")
	end)
	trove:Add(function()
		cleaned = true
	end)
	trove:Destroy()
	assert(cleaned, "one cleanup error prevented later objects from being cleaned")
end)

TestRunner.Test("Trove cleanup is safe when a callback destroys the same trove", function()
	local trove = Trove.new()
	local laterCleanupRan = false
	trove:Add(function()
		trove:Destroy()
	end)
	trove:Add(function()
		laterCleanupRan = true
	end)
	trove:Destroy()
	assert(laterCleanupRan, "reentrant cleanup skipped a later tracked object")
end)

TestRunner.Test("Trove:AttachToInstance cleans when an instance leaves the game", function()
	local trove = Trove.new()
	local folder = Instance.new("Folder")
	folder.Parent = workspace
	trove:AttachToInstance(folder)
	folder.Parent = nil
	task.wait()

	local ok = pcall(function()
		trove:Add(function() end)
	end)
	assert(not ok, "expected the trove to be destroyed after its instance left the game")
	folder:Destroy()
end)

--------------------------------------------------
-- Util: TableUtil
--------------------------------------------------

TestRunner.Test("TableUtil.Map / Filter / Reduce work on arrays", function()
	local nums = { 1, 2, 3, 4, 5 }

	local doubled = TableUtil.Map(nums, function(n)
		return n * 2
	end)
	assert(doubled[1] == 2 and doubled[5] == 10, "Map result mismatch")

	local evens = TableUtil.Filter(nums, function(n)
		return n % 2 == 0
	end)
	assert(#evens == 2 and evens[1] == 2 and evens[2] == 4, "Filter result mismatch")

	local sum = TableUtil.Reduce(nums, function(acc, n)
		return acc + n
	end, 0)
	assert(sum == 15, "Reduce result mismatch")
end)

TestRunner.Test("TableUtil.Filter passes array indices to its callback", function()
	local seen = {}
	TableUtil.Filter({ "a", "b" }, function(_value, index)
		table.insert(seen, index)
		return true
	end)
	assert(seen[1] == 1 and seen[2] == 2, "expected Filter callback to receive array indices")
end)

TestRunner.Test("TableUtil.Reconcile adds missing keys without dropping extras", function()
	local template = { kills = 0, deaths = 0 }
	local data = { kills = 10, extra = "keep me" }

	local result = TableUtil.Reconcile(data, template)

	assert(result.kills == 10 and result.deaths == 0 and result.extra == "keep me", "Reconcile result mismatch")
end)

TestRunner.Test("TableUtil.Copy(deep) does not alias nested tables", function()
	local original = { a = { b = 1 } }
	local copy = TableUtil.Copy(original, true)
	copy.a.b = 2

	assert(original.a.b == 1, "deep copy should not affect the original table")
end)

--------------------------------------------------
-- Util: Option
--------------------------------------------------

TestRunner.Test("Option.Wrap distinguishes Some and None", function()
	assert(Option.Wrap(nil):IsNone(), "expected None for a nil value")
	assert(Option.Wrap(5):IsSome(), "expected Some for a non-nil value")
	assert(Option.Wrap(5):Unwrap() == 5, "expected Unwrap to return the wrapped value")
end)

TestRunner.Test("Option:UnwrapOr and :Match behave correctly", function()
	assert(Option.None:UnwrapOr(42) == 42, "expected the default value from None")

	local matched = Option.Some(7):Match({
		Some = function(v)
			return v * 2
		end,
		None = function()
			return -1
		end,
	})

	assert(matched == 14, "expected the Some branch to run")
end)

TestRunner.Test("TableUtil.SwapRemove rejects out-of-range indexes", function()
	local values = { "a", "b" }
	local ok = pcall(TableUtil.SwapRemove, values, 0)
	assert(not ok and #values == 2 and values[1] == "a", "an invalid removal index corrupted the array")
end)

TestRunner.Test("TableUtil.Lock supports cyclic tables", function()
	local value = {} :: any
	value.self = value
	TableUtil.Lock(value)
	assert(table.isfrozen(value), "expected cyclic table to be frozen")
end)

TestRunner.Test("Option values are immutable", function()
	local ok = pcall(function()
		(Option.None :: any)._isSome = true
	end)
	assert(not ok and Option.None:IsNone(), "Option.None must not be mutable")
end)

--------------------------------------------------
-- Util: EnumList
--------------------------------------------------

TestRunner.Test("EnumList creates comparable, named items", function()
	local Direction = EnumList.new("Direction", { "North", "South" })

	assert(Direction.North.Name == "North", "expected the Name field to be set")
	assert(Direction.North.Value == 1, "expected the first item to have Value 1")
	assert(Direction:BelongsTo(Direction.North), "expected BelongsTo to recognize its own item")
	assert(Direction:FromName("South") == Direction.South, "expected FromName lookup to match")
	assert(Direction:FromValue(1) == Direction.North, "expected FromValue lookup to match")
end)

TestRunner.Test("EnumList does not expose a mutable item list", function()
	local Direction = EnumList.new("Direction", { "North", "South" })
	local items = Direction:GetEnumItems()
	local ok = pcall(function()
		table.remove(items)
	end)
	assert(not ok and #Direction:GetEnumItems() == 2, "enum item storage must be immutable")
end)

TestRunner.Test("EnumList rejects sparse name arrays", function()
	local ok = pcall(EnumList.new, "Sparse", { [2] = "Second" } :: any)
	assert(not ok, "a sparse enum definition was silently truncated")
end)

TestRunner.Test("TimerUtil debounce recovers after the wrapped function errors", function()
	local calls = 0
	local debounced = TimerUtil.Debounce(function()
		calls += 1
		if calls == 1 then
			error("expected")
		end
	end, 0)

	pcall(debounced)
	task.wait()
	debounced()
	assert(calls == 2, "debounce stayed locked after an error")
end)

TestRunner.Test("TimerUtil throttle always permits its first call", function()
	local calls = 0
	local throttled = TimerUtil.Throttle(function()
		calls += 1
	end, math.huge)
	throttled()
	assert(calls == 1, "throttle dropped its first call")
end)

TestRunner.Test("TimerUtil rejects negative intervals", function()
	assert(not pcall(TimerUtil.Debounce, function() end, -1), "Debounce accepted a negative interval")
	assert(not pcall(TimerUtil.Throttle, function() end, -1), "Throttle accepted a negative interval")
end)

local passed, failed = TestRunner.RunAll()
return table.freeze({
	Passed = passed,
	Failed = failed,
})
