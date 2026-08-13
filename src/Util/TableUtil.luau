--!strict
--[[
	TableUtil - helper functions for working with tables, filling gaps Lua's
	standard library leaves (Map/Filter/Reduce, deep copy, data reconciliation,
	etc.). Self-written for Thread, no external dependency.

	Except where noted, these treat tables as immutable and return a new
	table rather than mutating the input.
]]

local TableUtil = {}

--------------------------------------------------
-- Copying
--------------------------------------------------

-- Shallow copy by default; pass `deep = true` for a recursive copy.
-- Not protected against cyclical references when `deep` is true.
function TableUtil.Copy<T>(tbl: T, deep: boolean?): T
	if not deep then
		return (table.clone(tbl :: any) :: any) :: T
	end

	local function deepCopy(t: { [any]: any })
		local copy = table.clone(t)
		for k, v in pairs(copy) do
			if type(v) == "table" then
				copy[k] = deepCopy(v)
			end
		end
		return copy
	end

	return (deepCopy(tbl :: any) :: any) :: T
end

-- Two-way deep sync: `src` ends up with exactly the same keys as `template`
-- (missing keys added, extra keys removed, mismatched types overwritten).
-- Useful for config tables. For player save-data, prefer Reconcile below,
-- since Sync can silently discard data a template doesn't know about.
function TableUtil.Sync<S, T>(src: S, template: T): T
	assert(type(src) == "table", "TableUtil.Sync: src must be a table")
	assert(type(template) == "table", "TableUtil.Sync: template must be a table")

	local tbl = table.clone(src :: any)

	for k, v in pairs(tbl) do
		local templateValue = (template :: any)[k]

		if templateValue == nil then
			tbl[k] = nil
		elseif type(v) ~= type(templateValue) then
			tbl[k] = (type(templateValue) == "table") and TableUtil.Copy(templateValue, true) or templateValue
		elseif type(v) == "table" then
			tbl[k] = TableUtil.Sync(v, templateValue)
		end
	end

	for k, templateValue in pairs(template :: any) do
		if tbl[k] == nil then
			tbl[k] = (type(templateValue) == "table") and TableUtil.Copy(templateValue, true) or templateValue
		end
	end

	return (tbl :: any) :: T
end

-- One-way deep sync: any key present in `template` but missing from `src`
-- gets added, but nothing is ever removed from `src`. Safe for player data,
-- since fields the template doesn't know about are preserved.
function TableUtil.Reconcile<S, T>(src: S, template: T): S & T
	assert(type(src) == "table", "TableUtil.Reconcile: src must be a table")
	assert(type(template) == "table", "TableUtil.Reconcile: template must be a table")

	local tbl = table.clone(src :: any)

	for k, templateValue in pairs(template :: any) do
		local srcValue = (src :: any)[k]

		if srcValue == nil then
			tbl[k] = (type(templateValue) == "table") and TableUtil.Copy(templateValue, true) or templateValue
		elseif type(srcValue) == "table" and type(templateValue) == "table" then
			tbl[k] = TableUtil.Reconcile(srcValue, templateValue)
		end
	end

	return (tbl :: any) :: S & T
end

-- Deep-freezes a table (and every nested table) with table.freeze.
-- Mutates in place and returns the same table for convenience.
function TableUtil.Lock<T>(tbl: T): T
	local function lock(t: { [any]: any })
		for _, v in pairs(t) do
			if type(v) == "table" and not table.isfrozen(v) then
				lock(v)
			end
		end
		table.freeze(t)
	end

	lock(tbl :: any)
	return tbl
end

--------------------------------------------------
-- Arrays
--------------------------------------------------

-- O(1) removal that doesn't preserve order: swaps the last element into
-- index `i`, then trims the array. Prefer this over table.remove whenever
-- array order doesn't matter.
function TableUtil.SwapRemove<T>(tbl: { T }, i: number)
	local n = #tbl
	tbl[i] = tbl[n]
	tbl[n] = nil
end

function TableUtil.SwapRemoveFirstValue<T>(tbl: { T }, value: T): number?
	local index = table.find(tbl, value)
	if index then
		TableUtil.SwapRemove(tbl, index)
	end
	return index
end

function TableUtil.Reverse<T>(tbl: { T }): { T }
	local n = #tbl
	local out = table.create(n)
	for i = 1, n do
		out[i] = tbl[n - i + 1]
	end
	return out
end

function TableUtil.Shuffle<T>(tbl: { T }, rng: Random?): { T }
	local out = TableUtil.Copy(tbl)
	local random = rng or Random.new()

	for i = #out, 2, -1 do
		local j = random:NextInteger(1, i)
		out[i], out[j] = out[j], out[i]
	end

	return out
end

--------------------------------------------------
-- Functional helpers (work on arrays and dictionaries)
--------------------------------------------------

function TableUtil.Map<K, V, U>(tbl: { [K]: V }, fn: (value: V, key: K) -> U): { [K]: U }
	local out = {}
	for k, v in pairs(tbl) do
		out[k] = fn(v, k)
	end
	return out
end

-- Note: picks array-vs-dictionary behavior from `#tbl` - a table with both
-- an array part and separate string/dict keys will only have its array
-- part filtered. Keep arrays and dictionaries as separate tables if you
-- need both filtered.
function TableUtil.Filter<K, V>(tbl: { [K]: V }, fn: (value: V, key: K) -> boolean): { [K]: V }
	local out = {}
	local isArray = (#tbl > 0) or next(tbl) == nil

	if isArray then
		for _, v in ipairs(tbl :: any) do
			if fn(v, (nil :: any) :: K) then
				table.insert(out :: any, v)
			end
		end
	else
		for k, v in pairs(tbl) do
			if fn(v, k) then
				out[k] = v
			end
		end
	end

	return out
end

function TableUtil.Reduce<K, V, A>(tbl: { [K]: V }, fn: (acc: A, value: V, key: K) -> A, initial: A): A
	local acc = initial
	for k, v in pairs(tbl) do
		acc = fn(acc, v, k)
	end
	return acc
end

function TableUtil.Find<K, V>(tbl: { [K]: V }, fn: (value: V, key: K) -> boolean): (V?, K?)
	for k, v in pairs(tbl) do
		if fn(v, k) then
			return v, k
		end
	end
	return nil, nil
end

function TableUtil.Every<K, V>(tbl: { [K]: V }, fn: (value: V, key: K) -> boolean): boolean
	for k, v in pairs(tbl) do
		if not fn(v, k) then
			return false
		end
	end
	return true
end

function TableUtil.Some<K, V>(tbl: { [K]: V }, fn: (value: V, key: K) -> boolean): boolean
	for k, v in pairs(tbl) do
		if fn(v, k) then
			return true
		end
	end
	return false
end

function TableUtil.Keys<K, V>(tbl: { [K]: V }): { K }
	local out = {}
	for k in pairs(tbl) do
		table.insert(out, k)
	end
	return out
end

function TableUtil.Values<K, V>(tbl: { [K]: V }): { V }
	local out = {}
	for _, v in pairs(tbl) do
		table.insert(out, v)
	end
	return out
end

function TableUtil.IsEmpty(tbl: { [any]: any }): boolean
	return next(tbl) == nil
end

function TableUtil.Length(tbl: { [any]: any }): number
	local count = 0
	for _ in pairs(tbl) do
		count += 1
	end
	return count
end

return TableUtil
