--!strict
--[[
	MathUtil - small numeric helpers Roblox's `math` library doesn't already
	provide (math.clamp/round/sign/noise etc. cover the rest). Self-written
	for Thread, no external dependency.

	MathUtil.Lerp(0, 10, 0.5)                  --> 5
	MathUtil.MapRange(0.5, 0, 1, 0, 100)       --> 50
	MathUtil.FuzzyEquals(0.1 + 0.2, 0.3, 1e-9) --> true
]]

local MathUtil = {}

function MathUtil.Lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Rescales `value` from the `inMin..inMax` range into `outMin..outMax`.
-- Passing inMin == inMax divides by zero (inf/nan, not an error) - callers
-- own that check.
function MathUtil.MapRange(value: number, inMin: number, inMax: number, outMin: number, outMax: number): number
	return (value - inMin) * (outMax - outMin) / (inMax - inMin) + outMin
end

function MathUtil.FuzzyEquals(a: number, b: number, epsilon: number): boolean
	return math.abs(a - b) <= epsilon
end

return MathUtil
