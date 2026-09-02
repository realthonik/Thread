--!strict

local result = require(script.Parent["Thread.spec"])
if result.Failed > 0 then
	error(("Thread unit test suite failed: %d passed, %d failed"):format(result.Passed, result.Failed), 0)
end
