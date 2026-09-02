--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LogService = game:GetService("LogService")
local StudioTestService = game:GetService("StudioTestService")

if StudioTestService:GetTestArgs() ~= "ThreadIntegration" then
	return
end

local Thread = require(ReplicatedStorage.Packages.Thread)
local unitResult = require(game:GetService("ServerScriptService").UnitTests["Thread.spec"])
if unitResult.Failed > 0 then
	StudioTestService:EndTest(("FAIL: %d unit tests failed"):format(unitResult.Failed))
	return
end

local resultRemote = Instance.new("RemoteEvent")
resultRemote.Name = "ThreadIntegrationResult"
resultRemote.Parent = ReplicatedStorage

local rateWarningCount = 0
local logConnection = LogService.MessageOut:Connect(function(message)
	if
		string.find(message, "Rate limit exceeded:", 1, true)
		and string.find(message, "IntegrationService.Limited", 1, true)
	then
		rateWarningCount += 1
	end
end)

local IntegrationService = Thread.CreateService({
	Name = "IntegrationService",
	MaxPayloadBytes = 256,
	RemotePolicies = {
		Validated = {
			Arguments = { Thread.Validators.Number },
			AllowExtraArguments = false,
		},
		Limited = {
			RateLimit = 1,
		},
	},
	Middleware = {
		Inbound = {
			function(_player, args)
				return args[1] ~= "block"
			end,
		},
	},
	Client = {
		Ping = Thread.CreateSignal(),
		State = Thread.CreateProperty("initial"),
	},
})

function IntegrationService.Client:Echo(_player: Player, ...: any): ...any
	return ...
end

function IntegrationService.Client:Validated(_player: Player, value: number): number
	return value * 2
end

function IntegrationService.Client:Limited(_player: Player): boolean
	return true
end

function IntegrationService.Client:Fail(_player: Player)
	error("intentional integration failure")
end

function IntegrationService.Client:Maybe(_player: Player, _mode: string): nil
	return nil
end

function IntegrationService.Client:GetRateWarningCount(_player: Player): number
	return rateWarningCount
end

function IntegrationService.Client:SetState(_player: Player, value: string): boolean
	self.State:Set(value)
	return true
end

function IntegrationService:ThreadInit()
	return Thread.Promise.delay(0.02)
end

function IntegrationService:ThreadStart()
	return Thread.Promise.delay(0.02):andThen(function()
		self.Client.Ping:Connect(function(player: Player, message: string)
			if message == "from-client" then
				self.Client.Ping:Fire(player, "from-server")
			end
		end)
	end)
end

function IntegrationService:ThreadStop()
	logConnection:Disconnect()
end

local finished = false
local resultConnection
resultConnection = resultRemote.OnServerEvent:Connect(function(_player: Player, success: boolean, message: string?)
	if finished then
		return
	end
	finished = true
	resultConnection:Disconnect()
	task.spawn(function()
		local stopOk, stopError = pcall(function()
			Thread.Stop():await()
		end)
		if not stopOk then
			StudioTestService:EndTest("FAIL: shutdown failed: " .. tostring(stopError))
		elseif success then
			StudioTestService:EndTest("PASS")
		else
			StudioTestService:EndTest("FAIL: " .. tostring(message))
		end
	end)
end)

Thread.Start():catch(function(err)
	if not finished then
		finished = true
		StudioTestService:EndTest("FAIL: startup failed: " .. tostring(err))
	end
end)

task.delay(20, function()
	if not finished then
		finished = true
		StudioTestService:EndTest("FAIL: client integration test timed out")
	end
end)
