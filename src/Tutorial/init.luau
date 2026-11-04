--!strict
--[[
	Tutorial: the server side of the onboarding coachmarks (brief §5.5, §8 onboarding funnel).
	The client overlay (Screens.Tutorial) shows one step at a time and reports each one; the
	server keeps which step the player reached in their profile and sends every first-time
	step to analytics, so the funnel shows where new players stop.

	  local tutorial = Shared.Tutorial.new({
	  	steps = { "move", "firstJump", "openShop", "firstWin" },
	  	analytics = analytics,                 -- analytics:onboarding(player, step, stepName)
	  })
	  tutorial:bindStore(Profiles)
	  tutorial:bindNet()
	  -- Steps the server sees happen itself can be completed from game code:
	  tutorial:complete(player, "firstWin")

	Steps complete in order. Completing a later step completes every step before it (the
	player found the way on their own); each step is reported to analytics once, ever. A
	skipped tutorial reports nothing more, so skips show as drop-off in the funnel.
]]

local Remotes = require("./Remotes")
local Roblox = require("./Util/Roblox")
local Signal = require("./Signal")
local Slots = require("./Util/Slots")

export type Options = {
	steps: { string },
	analytics: any?,
	field: string?,
	now: (() -> number)?,
	players: any?,
}

export type State = {
	-- Steps completed (0 = none).
	step: number,
	skipped: boolean,
	-- os.time() the tutorial finished or was skipped.
	doneAt: number?,
	-- Highest step ever sent to analytics, so a reset never reports a step twice.
	reported: number?,
}

export type Status = {
	step: number,
	total: number,
	done: boolean,
	skipped: boolean,
	-- Id of the next step to show, if any.
	next: string?,
}

export type Tutorial = {
	-- (player?, userId, index, stepId) once per step, in order.
	Advanced: Signal.Signal<any, number, number, string>,
	-- (player?, userId, skipped) when the last step completes or the player skips.
	Finished: Signal.Signal<any, number, boolean>,

	bindStore: (self: Tutorial, store: any) -> (),
	attach: (self: Tutorial, who: any, data: any) -> (),
	detach: (self: Tutorial, who: any) -> (),
	isAttached: (self: Tutorial, who: any) -> boolean,
	steps: (self: Tutorial) -> { string },
	status: (self: Tutorial, who: any) -> Status?,
	-- Completes `stepId` and every step before it. False with "unknown" or "notLoaded".
	complete: (self: Tutorial, who: any, stepId: string) -> (boolean, string?),
	skip: (self: Tutorial, who: any) -> (boolean, string?),
	-- Starts the tutorial over (admin, testing). Analytics is not sent again for steps done before.
	reset: (self: Tutorial, who: any) -> (),
	bindNet: (self: Tutorial, context: any?) -> any,
}

local Tutorial = {}

function Tutorial.newState(): State
	return { step = 0, skipped = false }
end

function Tutorial.repair(state: any): State
	local step = if type(state) == "table" then state.step else nil
	local doneAt = if type(state) == "table" then state.doneAt else nil
	return {
		step = if type(step) == "number"
				and step == step
				and step >= 0
				and step < math.huge
			then math.floor(step)
			else 0,
		skipped = type(state) == "table" and state.skipped == true,
		doneAt = if type(doneAt) == "number" and doneAt == doneAt and doneAt >= 0 then doneAt else nil,
		reported = if type(state) == "table" and type(state.reported) == "number" then state.reported else nil,
	}
end

function Tutorial.new(options: Options): Tutorial
	local steps = options.steps
	assert(type(steps) == "table" and #steps > 0, "Tutorial.new: steps must be a non-empty list of ids")
	local indexOf: { [string]: number } = {}
	for index, id in steps do
		assert(type(id) == "string" and string.match(id, "^[%w_:%.%-]+$"), "Tutorial.new: bad step id " .. tostring(id))
		assert(indexOf[id] == nil, "Tutorial.new: duplicate step " .. id)
		indexOf[id] = index
	end
	local now: () -> number = options.now or os.time
	local slots = Slots.new(options.field or "tutorial", Tutorial.newState, Tutorial.repair)

	local tutorial = { Advanced = Signal.new(), Finished = Signal.new() } :: Tutorial

	function tutorial.bindStore(self: Tutorial, store: any)
		slots:bindStore(store)
		local players = options.players
		if players == nil and Roblox.isRoblox() then
			players = Roblox.service("Players")
		end
		if players then
			for _, player in players:GetPlayers() do
				local profile = store:get(player)
				if profile and not slots:isAttached(player) then
					self:attach(player, function()
						return profile.data
					end)
				end
			end
		end
	end

	function tutorial.attach(_self: Tutorial, who: any, data: any)
		slots:attach(who, data)
	end

	function tutorial.detach(_self: Tutorial, who: any)
		slots:detach(who)
	end

	function tutorial.isAttached(_self: Tutorial, who: any): boolean
		return slots:isAttached(who)
	end

	function tutorial.steps(_self: Tutorial): { string }
		return table.clone(steps)
	end

	function tutorial.status(_self: Tutorial, who: any): Status?
		local state = slots:get(who)
		if state == nil then
			return nil
		end
		local done = state.skipped or state.step >= #steps
		return {
			step = state.step,
			total = #steps,
			done = done,
			skipped = state.skipped,
			next = if done then nil else steps[state.step + 1],
		}
	end

	function tutorial.complete(self: Tutorial, who: any, stepId: string): (boolean, string?)
		local state = slots:get(who)
		if state == nil then
			return false, "notLoaded"
		end
		local index = indexOf[stepId]
		if index == nil then
			return false, "unknown"
		end
		if index <= state.step then
			return true, nil
		end
		local player = slots:player(who)
		local userId = Slots.userIdOf(who) :: number
		local sink = options.analytics
		for i = state.step + 1, index do
			state.step = i
			if (state.reported or 0) < i then
				state.reported = i
				if sink and player and type(sink.onboarding) == "function" then
					sink:onboarding(player, i, steps[i])
				end
			end
			self.Advanced:Fire(player, userId, i, steps[i])
		end
		if state.step >= #steps and not state.skipped then
			state.doneAt = now()
			self.Finished:Fire(player, userId, false)
		end
		return true, nil
	end

	function tutorial.skip(self: Tutorial, who: any): (boolean, string?)
		local state = slots:get(who)
		if state == nil then
			return false, "notLoaded"
		end
		if state.skipped or state.step >= #steps then
			return true, nil
		end
		state.skipped = true
		state.doneAt = now()
		self.Finished:Fire(slots:player(who), Slots.userIdOf(who) :: number, true)
		return true, nil
	end

	function tutorial.reset(_self: Tutorial, who: any)
		local state = slots:get(who)
		if state then
			state.step = 0
			state.skipped = false
			state.doneAt = nil
		end
	end

	function tutorial.bindNet(self: Tutorial, context: any?): any
		return Remotes.serve("Tutorial", self, context)
	end

	return tutorial
end

return Tutorial
