--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Thread = require(ReplicatedStorage.Packages.Thread)
local Channel = Thread.Channel
local resultRemote = ReplicatedStorage:WaitForChild("ThreadIntegrationResult", 10) :: RemoteEvent

local function check(condition: any, message: string)
	if not condition then
		error(message, 2)
	end
end

local success, failure = xpcall(function()
	local service = Channel.BuildClient("IntegrationService", 10)

	local first, second, third = service:Echo("value", nil, 42)
	check(first == "value" and second == nil and third == 42, "BuildClient method lost tuple values")
	check(service:Validated(4) == 8, "validated method returned the wrong value")

	local validationOk, validationError = pcall(function()
		service:Validated("wrong")
	end)
	check(not validationOk and Channel.IsRemoteError(validationError), "validation did not return a structured error")
	check(validationError.Code == "VALIDATION_FAILED", "validation returned the wrong error code")

	local handlerOk, handlerError = pcall(function()
		service:Fail()
	end)
	check(not handlerOk and Channel.IsRemoteError(handlerError), "handler failure did not return a structured error")
	check(handlerError.Code == "HANDLER_ERROR", "handler failure returned the wrong error code")

	local payloadOk, payloadError = pcall(function()
		service:Echo(string.rep("x", 1024))
	end)
	check(not payloadOk and Channel.IsRemoteError(payloadError), "oversized payload did not return a structured error")
	check(payloadError.Code == "PAYLOAD_TOO_LARGE", "oversized payload returned the wrong error code")

	local maybeResult = table.pack(service:Maybe("allow"))
	check(maybeResult.n == 1 and maybeResult[1] == nil, "legitimate nil response was not preserved")
	local middlewareOk, middlewareError = pcall(function()
		service:Maybe("block")
	end)
	check(not middlewareOk and Channel.IsRemoteError(middlewareError), "middleware rejection was not structured")
	check(middlewareError.Code == "MIDDLEWARE_REJECTED", "middleware rejection returned the wrong error code")

	check(service:Limited() == true, "token bucket rejected its initial token")
	local limitedOk, limitedError = pcall(function()
		service:Limited()
	end)
	check(not limitedOk and Channel.IsRemoteError(limitedError), "rate limit did not return a structured error")
	check(limitedError.Code == "RATE_LIMITED", "rate limit returned the wrong error code")
	for _ = 1, 3 do
		local repeatedOk, repeatedError = pcall(function()
			service:Limited()
		end)
		check(
			not repeatedOk and Channel.IsRemoteError(repeatedError) and repeatedError.Code == "RATE_LIMITED",
			"repeated rate-limited call returned the wrong result"
		)
	end
	task.wait()
	check(service:GetRateWarningCount() == 1, "rate-limit warning output was not throttled")
	task.wait(1.05)
	check(service:Limited() == true, "token bucket did not refill continuously")

	local signalValue: string? = nil
	local connection = service.Ping:Connect(function(value: string)
		signalValue = value
	end)
	service.Ping:Fire("from-client")
	local signalDeadline = os.clock() + 3
	while signalValue == nil and os.clock() < signalDeadline do
		task.wait()
	end
	connection:Disconnect()
	check(signalValue == "from-server", "service signal did not round-trip")

	check(service.State:Get() == "initial", "property initial sync failed")
	local observed: string? = nil
	local observation = service.State:Observe(function(value: string)
		observed = value
	end)
	check(service:SetState("updated") == true, "property update method failed")
	local propertyDeadline = os.clock() + 3
	while observed ~= "updated" and os.clock() < propertyDeadline do
		task.wait()
	end
	observation:Disconnect()
	check(service.State:Get() == "updated" and observed == "updated", "property update did not replicate")
end, debug.traceback)

resultRemote:FireServer(success, if success then nil else tostring(failure))
