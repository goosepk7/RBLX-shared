--!strict
--[[
	Discrete-event scheduler for sims: events fire in (time, insertion) order, so a run is fully
	deterministic. Use it to model a server over days (sessions, events every N minutes,
	autosaves) without stepping every second.

	  local sched = Scheduler.new()
	  sched:every(12 * 60, startServerEvent)           -- every 12 minutes
	  sched:after(25, function() ... end)
	  sched:runUntil(14 * 86400)

	For tight physics-like loops use Scheduler.fixedStep(dt, duration, fn).
]]

export type Handle = { cancel: (self: Handle) -> (), cancelled: boolean }

export type EveryOptions = {
	-- First fire time (absolute). Default now + interval.
	start: number?,
	-- Stop after this many fires.
	count: number?,
	-- Do not fire after this absolute time.
	untilTime: number?,
}

export type Scheduler = {
	now: (self: Scheduler) -> number,
	at: (self: Scheduler, time: number, fn: (now: number) -> ()) -> Handle,
	after: (self: Scheduler, delay: number, fn: (now: number) -> ()) -> Handle,
	every: (
		self: Scheduler,
		interval: number,
		fn: (now: number, index: number) -> (),
		options: EveryOptions?
	) -> Handle,
	step: (self: Scheduler) -> boolean,
	runUntil: (self: Scheduler, time: number) -> number,
	runAll: (self: Scheduler, maxEvents: number?) -> number,
	pending: (self: Scheduler) -> number,
	processed: (self: Scheduler) -> number,
}

type Event = { time: number, seq: number, fn: (number) -> (), handle: Handle }

local Scheduler = {}

function Scheduler.new(start: number?): Scheduler
	local current = start or 0
	local heap: { Event } = {}
	local seq = 0
	local processedCount = 0

	local function less(a: Event, b: Event): boolean
		if a.time == b.time then
			return a.seq < b.seq
		end
		return a.time < b.time
	end

	local function push(event: Event)
		table.insert(heap, event)
		local i = #heap
		while i > 1 do
			local parent = i // 2
			if less(heap[i], heap[parent]) then
				heap[i], heap[parent] = heap[parent], heap[i]
				i = parent
			else
				break
			end
		end
	end

	local function pop(): Event?
		local count = #heap
		if count == 0 then
			return nil
		end
		local top = heap[1]
		heap[1] = heap[count]
		heap[count] = nil
		count -= 1
		local i = 1
		while true do
			local left = i * 2
			local right = left + 1
			local smallest = i
			if left <= count and less(heap[left], heap[smallest]) then
				smallest = left
			end
			if right <= count and less(heap[right], heap[smallest]) then
				smallest = right
			end
			if smallest == i then
				break
			end
			heap[i], heap[smallest] = heap[smallest], heap[i]
			i = smallest
		end
		return top
	end

	local function newHandle(): Handle
		local handle = { cancelled = false } :: Handle
		function handle.cancel(h: Handle)
			h.cancelled = true
		end
		return handle
	end

	local self = {} :: Scheduler

	function self.now(_self: Scheduler): number
		return current
	end

	local function schedule(time: number, fn: (number) -> (), handle: Handle): Handle
		assert(time == time, "Scheduler: time is NaN")
		seq += 1
		push({ time = math.max(time, current), seq = seq, fn = fn, handle = handle })
		return handle
	end

	function self.at(_self: Scheduler, time: number, fn: (now: number) -> ()): Handle
		return schedule(time, fn, newHandle())
	end

	function self.after(_self: Scheduler, delay: number, fn: (now: number) -> ()): Handle
		assert(delay >= 0, "Scheduler:after expects a non-negative delay")
		return schedule(current + delay, fn, newHandle())
	end

	function self.every(
		_self: Scheduler,
		interval: number,
		fn: (now: number, index: number) -> (),
		options: EveryOptions?
	): Handle
		assert(interval > 0, "Scheduler:every expects a positive interval")
		local opts: EveryOptions = options or {}
		local handle = newHandle()
		local index = 0
		local function fire(now: number)
			index += 1
			fn(now, index)
			local nextTime = now + interval
			local more = (opts.count == nil or index < opts.count)
				and (opts.untilTime == nil or nextTime <= opts.untilTime)
			if more and not handle.cancelled then
				schedule(nextTime, fire, handle)
			end
		end
		local first = opts.start or (current + interval)
		if opts.untilTime == nil or first <= opts.untilTime then
			schedule(first, fire, handle)
		end
		return handle
	end

	function self.step(_self: Scheduler): boolean
		while true do
			local event = pop()
			if not event then
				return false
			end
			if not event.handle.cancelled then
				current = event.time
				processedCount += 1
				event.fn(current)
				return true
			end
		end
	end

	-- Runs every event with time <= `time`, then sets now to `time`. Returns events processed.
	function self.runUntil(s: Scheduler, time: number): number
		local before = processedCount
		while heap[1] and heap[1].time <= time do
			s:step()
		end
		if time > current then
			current = time
		end
		return processedCount - before
	end

	function self.runAll(s: Scheduler, maxEvents: number?): number
		local limit = maxEvents or 10_000_000
		local before = processedCount
		while s:step() do
			if processedCount - before >= limit then
				error(string.format("Scheduler:runAll exceeded %d events (runaway loop?)", limit))
			end
		end
		return processedCount - before
	end

	function self.pending(_self: Scheduler): number
		return #heap
	end

	function self.processed(_self: Scheduler): number
		return processedCount
	end

	return self
end

-- Calls fn(t, dt) for t = 0, dt, 2dt ... < duration. Returns the number of steps. Use an
-- integer step counter (not t += dt) so long runs do not drift.
function Scheduler.fixedStep(dt: number, duration: number, fn: (t: number, dt: number) -> boolean?): number
	assert(dt > 0, "fixedStep expects dt > 0")
	local steps = math.ceil(duration / dt - 1e-9)
	for i = 0, steps - 1 do
		if fn(i * dt, dt) == false then
			return i + 1
		end
	end
	return steps
end

return Scheduler
