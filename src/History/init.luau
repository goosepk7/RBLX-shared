--!strict
--[[
	History: undo and redo over snapshots, for editors (the car builder, admin tools).

		local history = History.new({ limit = 100 })
		history:reset(design:snapshot())
		-- after every user action:
		history:push(design:snapshot(), "add member")
		-- Undo button:
		local state, label = history:undo()
		if state then design:restore(state) end

	Snapshot-based on purpose: each entry is the whole state after a step, so undo can never
	drift from what the player saw (no inverse operations to get wrong). States are opaque to
	History; the caller hands in values it won't mutate afterwards (a fresh copy, or frozen).

	- `push` after a change records it, drops anything that could be redone, and forgets the
	  oldest step past `limit`. A push equal to the current state (by `equals`) is ignored, so
	  "tap the same thing twice" doesn't add an empty undo step.
	- `undo` returns the state to restore and the label of the step it undid; `redo` returns the
	  state to restore and the label of the step it redid. Both return nil when there's nothing.
]]

export type Options = {
	limit: number?, -- most undo steps kept (default 100)
	equals: ((a: any, b: any) -> boolean)?, -- skip pushes equal to the current state
}

export type History = {
	reset: (self: History, state: any) -> (),
	push: (self: History, state: any, label: string?) -> boolean,
	undo: (self: History) -> (any, string?),
	redo: (self: History) -> (any, string?),
	current: (self: History) -> any,
	canUndo: (self: History) -> boolean,
	canRedo: (self: History) -> boolean,
	undoLabel: (self: History) -> string?,
	redoLabel: (self: History) -> string?,
	size: (self: History) -> number,
}

type Entry = { state: any, label: string? }

local History = {}

History.DEFAULT_LIMIT = 100

function History.new(options: Options?): History
	local o: Options = options or {}
	local limit = o.limit or History.DEFAULT_LIMIT
	if type(limit) ~= "number" or limit < 1 or limit % 1 ~= 0 then
		error("History.new: limit must be a whole number of at least 1", 2)
	end
	local equals = o.equals
	-- entries[1] is the base state; entries[i] for i > 1 is the state after step i - 1.
	local entries: { Entry } = {}
	local index = 0

	local self = {}

	function self.reset(_self: History, state: any)
		entries = { { state = state, label = nil } }
		index = 1
	end

	function self.push(_self: History, state: any, label: string?): boolean
		if index == 0 then
			error("History:push before reset: give it the starting state first", 2)
		end
		if equals and equals(entries[index].state, state) then
			return false
		end
		for i = #entries, index + 1, -1 do
			entries[i] = nil
		end
		table.insert(entries, { state = state, label = label })
		index = #entries
		while #entries > limit + 1 do
			table.remove(entries, 1)
			index -= 1
		end
		return true
	end

	function self.undo(_self: History): (any, string?)
		if index <= 1 then
			return nil, nil
		end
		local undone = entries[index].label
		index -= 1
		return entries[index].state, undone
	end

	function self.redo(_self: History): (any, string?)
		if index == 0 or index >= #entries then
			return nil, nil
		end
		index += 1
		return entries[index].state, entries[index].label
	end

	function self.current(_self: History): any
		local entry = entries[index]
		return if entry then entry.state else nil
	end

	function self.canUndo(_self: History): boolean
		return index > 1
	end

	function self.canRedo(_self: History): boolean
		return index > 0 and index < #entries
	end

	function self.undoLabel(_self: History): string?
		return if index > 1 then entries[index].label else nil
	end

	function self.redoLabel(_self: History): string?
		return if index > 0 and index < #entries then entries[index + 1].label else nil
	end

	function self.size(_self: History): number
		return math.max(0, #entries - 1)
	end

	return (self :: any) :: History
end

return History
