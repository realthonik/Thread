--!strict
--[[
	TimerUtil - debounce/throttle wrappers for rate-limiting how often a
	function runs. Self-written for Thread, no external dependency.

	local onClick = TimerUtil.Debounce(function()
		print("clicked")
	end, 1)

	button.MouseButton1Click:Connect(onClick) -- ignores clicks within 1s of the last one
]]

local TimerUtil = {}

-- Wraps `fn` so the first call runs immediately, then any call within
-- `seconds` after that is ignored until the cooldown expires. The classic
-- "debounce" idiom for things like preventing a Touched event from double-firing.
function TimerUtil.Debounce<T...>(fn: (T...) -> (), seconds: number): (T...) -> ()
	assert(type(fn) == "function", "TimerUtil.Debounce: fn must be a function")
	assert(type(seconds) == "number" and seconds >= 0, "TimerUtil.Debounce: seconds must be non-negative")
	local ready = true
	return function(...: T...)
		if not ready then
			return
		end
		ready = false
		task.delay(seconds, function()
			ready = true
		end)
		fn(...)
	end
end

-- Wraps `fn` so it runs at most once every `seconds` - the first call in a
-- burst runs immediately, calls before the interval elapses are dropped
-- (no trailing call is scheduled for them).
function TimerUtil.Throttle<T...>(fn: (T...) -> (), seconds: number): (T...) -> ()
	assert(type(fn) == "function", "TimerUtil.Throttle: fn must be a function")
	assert(type(seconds) == "number" and seconds >= 0, "TimerUtil.Throttle: seconds must be non-negative")
	local lastRun = -math.huge
	return function(...: T...)
		local now = os.clock()
		if now - lastRun < seconds then
			return
		end
		lastRun = now
		fn(...)
	end
end

return TimerUtil
