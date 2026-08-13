--!strict
--[[
	EnumList - defines a custom, strongly-comparable enum, since Luau has no
	built-in way to declare your own Enum types the way Roblox's engine
	Enums work.

	Self-written for Thread, no external dependency.

	local Direction = EnumList.new("Direction", { "North", "South", "East", "West" })

	print(Direction.North.Name)       --> "North"
	print(Direction.North.Value)      --> 1
	print(Direction:BelongsTo(Direction.North)) --> true
	print(Direction:FromName("South") == Direction.South) --> true
]]

export type EnumItem = {
	Name: string,
	Value: number,
	EnumType: any,
}

export type EnumList = {
	BelongsTo: (self: EnumList, obj: any) -> boolean,
	GetEnumItems: (self: EnumList) -> { EnumItem },
	GetName: (self: EnumList) -> string,
	FromName: (self: EnumList, name: string) -> EnumItem?,
	FromValue: (self: EnumList, value: number) -> EnumItem?,
	[string]: any,
}

local LIST_KEY = newproxy()
local NAME_KEY = newproxy()

local function createEnumItem(name: string, value: number, enumList: any): EnumItem
	local item = {
		Name = name,
		Value = value,
		EnumType = enumList,
	}
	table.freeze(item)
	return item
end

local EnumList = {}
EnumList.__index = EnumList

function EnumList.new(name: string, names: { string }): EnumList
	assert(type(name) == "string", "EnumList.new: name must be a string")
	assert(type(names) == "table", "EnumList.new: names must be a table of strings")

	local self: any = setmetatable({}, EnumList)
	self[LIST_KEY] = {}
	self[NAME_KEY] = name

	for i, itemName in ipairs(names) do
		assert(type(itemName) == "string", "EnumList.new: every enum name must be a string")
		assert(self[itemName] == nil, ("EnumList.new: duplicate enum name '%s'"):format(itemName))

		local item = createEnumItem(itemName, i, self)
		self[itemName] = item
		table.insert(self[LIST_KEY], item)
	end

	return table.freeze(self) :: EnumList
end

function EnumList:BelongsTo(obj: any): boolean
	return type(obj) == "table" and obj.EnumType == self
end

function EnumList:GetEnumItems(): { EnumItem }
	return (self :: any)[LIST_KEY]
end

function EnumList:GetName(): string
	return (self :: any)[NAME_KEY]
end

function EnumList:FromName(name: string): EnumItem?
	local item = (self :: any)[name]
	if type(item) == "table" and item.EnumType == self then
		return item
	end
	return nil
end

function EnumList:FromValue(value: number): EnumItem?
	for _, item in ipairs(self:GetEnumItems()) do
		if item.Value == value then
			return item
		end
	end
	return nil
end

return EnumList
