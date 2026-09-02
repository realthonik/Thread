local StudioTestService = game:GetService("StudioTestService")
local RunService = game:GetService("RunService")

-- run-in-roblox's plugin is cloned into the play DataModel. Only the edit
-- DataModel should start and await the test session.
if RunService:IsRunning() then
	while RunService:IsRunning() do
		RunService.Heartbeat:Wait()
	end
	return
end

local result = StudioTestService:ExecutePlayModeAsync("ThreadIntegration")

if result ~= "PASS" then
	error("Thread integration test failed: " .. tostring(result), 0)
end

print("Thread server/client integration test passed")
