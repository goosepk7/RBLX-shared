--!strict
--[[
	A stand-in for Instance.new under lune, for modules that build Instances through an
	injected `createInstance(className)` (Audio, VFX, Settings apply code).

		local fakes = T.Fakes.Instances.new()
		local audio = Audio.new({ createInstance = fakes.create, parent = fakes.create("SoundService") })
		fakes:count("Sound") --> how many were made

	A fake takes any property assignment. It implements the methods those modules call:
	Play/Stop/Pause/Resume (IsPlaying, an `Ended` signal you fire with `:finish()`), Emit
	(adds to `emitted`), Destroy (Parent = nil, Destroyed = true), GetChildren, FindFirstChild,
	GetAttribute/SetAttribute, and Clone. Parent assignment keeps children lists in sync.
]]

local Signal = require("../Signal")

export type FakeInstance = { [string]: any }

export type FakeInstances = {
	created: { FakeInstance },
	create: (className: string) -> FakeInstance,
	count: (self: FakeInstances, className: string, alive: boolean?) -> number,
	all: (self: FakeInstances, className: string) -> { FakeInstance },
}

local Instances = {}

function Instances.new(): FakeInstances
	local created: { FakeInstance } = {}
	local fakes = { created = created } :: FakeInstances

	local function make(className: string): FakeInstance
		local children: { FakeInstance } = {}
		local attributes: { [string]: any } = {}
		local props: { [string]: any } = {
			ClassName = className,
			Name = className,
			IsPlaying = false,
			Destroyed = false,
			emitted = 0,
			plays = 0,
		}
		local fake: any = {}
		local methods: { [string]: any } = {
			Ended = Signal.new(),
			Play = function(self: FakeInstance)
				self.IsPlaying = true
				self.plays += 1
			end,
			Resume = function(self: FakeInstance)
				self.IsPlaying = true
			end,
			Stop = function(self: FakeInstance)
				self.IsPlaying = false
			end,
			Pause = function(self: FakeInstance)
				self.IsPlaying = false
			end,
			finish = function(self: FakeInstance)
				self.IsPlaying = false
				self.Ended:Fire(self.SoundId)
			end,
			Emit = function(self: FakeInstance, n: number?)
				self.emitted += n or 1
			end,
			Destroy = function(self: FakeInstance)
				for _, child in table.clone(children) do
					child:Destroy()
				end
				self.Parent = nil
				self.Destroyed = true
				self.IsPlaying = false
			end,
			GetChildren = function(_self: FakeInstance)
				return table.clone(children)
			end,
			FindFirstChild = function(_self: FakeInstance, name: string): FakeInstance?
				for _, child in children do
					if child.Name == name then
						return child
					end
				end
				return nil
			end,
			GetAttribute = function(_self: FakeInstance, key: string)
				return attributes[key]
			end,
			SetAttribute = function(_self: FakeInstance, key: string, value: any)
				attributes[key] = value
			end,
			Clone = function(_self: FakeInstance)
				local copy = make(className)
				for key, value in props do
					if key ~= "Parent" then
						copy[key] = value
					end
				end
				return copy
			end,
			_children = children,
		}
		setmetatable(fake, {
			__index = function(_, key: string)
				local method = methods[key]
				if method ~= nil then
					return method
				end
				return props[key]
			end,
			__newindex = function(self: any, key: string, value: any)
				if key == "Parent" then
					local old = props.Parent
					if old ~= nil then
						local list = old._children
						local i = table.find(list, self)
						if i then
							table.remove(list, i)
						end
					end
					if value ~= nil and type(value) == "table" and value._children then
						table.insert(value._children, self)
					end
				end
				props[key] = value
			end,
		})
		table.insert(created, fake)
		return fake :: FakeInstance
	end

	fakes.create = make

	function fakes.count(_self: FakeInstances, className: string, alive: boolean?): number
		local n = 0
		for _, fake in created do
			if fake.ClassName == className and (not alive or not fake.Destroyed) then
				n += 1
			end
		end
		return n
	end

	function fakes.all(_self: FakeInstances, className: string): { FakeInstance }
		local out: { FakeInstance } = {}
		for _, fake in created do
			if fake.ClassName == className then
				table.insert(out, fake)
			end
		end
		return out
	end

	return fakes
end

return Instances
