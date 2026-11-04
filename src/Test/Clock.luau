--!strict
--[[
	Virtual clock for deterministic tests and sims of time-dependent code (autosave, backoff,
	rate limits, cooldowns). Nothing here touches real time.

	Two time bases, matching what Roblox code usually reads:
	  clock:now()    unix seconds (os.time-like, fractional allowed)  -> lock stamps, expiries
	  clock:clock()  monotonic seconds since the clock was created   -> os.clock()-like deltas

	The clock also emulates the Roblox `task` library (clock.task) so code that schedules work
	can be driven step by step:

	  local clock = Clock.new()
	  clock.task.delay(60, autosave)
	  clock:advance(59) -- nothing yet
	  clock:advance(1)  -- autosave runs, at exactly t = 60

	`wait` inside a thread the clock started (task.spawn / task.delay / task.defer) yields that
	thread until virtual time reaches the deadline. `wait` from the test body itself (any thread
	the clock did not start) advances the clock synchronously, so straight-line test code works.

	Errors raised inside clock-run threads are rethrown from the advance()/flush() call that ran
	them, so a failing background task fails the test instead of vanishing.
]]

export type TaskLib = {
	wait: (seconds: number?) -> number,
	spawn: (fnOrThread: any, ...any) -> thread,
	defer: (fnOrThread: any, ...any) -> thread,
	delay: (seconds: number?, fnOrThread: any, ...any) -> thread,
	cancel: (thread: thread) -> (),
}

export type Deps = {
	now: () -> number,
	clock: () -> number,
	wait: (seconds: number) -> (),
}

export type Clock = {
	task: TaskLib,
	now: (self: Clock) -> number,
	clock: (self: Clock) -> number,
	advance: (self: Clock, seconds: number) -> (),
	advanceTo: (self: Clock, monotonic: number) -> (),
	flush: (self: Clock) -> (),
	wait: (self: Clock, seconds: number?) -> number,
	pending: (self: Clock) -> number,
	nextDeadline: (self: Clock) -> number?,
	deps: (self: Clock) -> Deps,
}

export type Options = {
	-- Unix time at monotonic 0. Default 1_700_000_000 (2023-11-14), fixed so output is stable.
	start: number?,
	-- Smallest wait, like Roblox's ~1 frame minimum. Default 1/60.
	minWait: number?,
}

type Timer = {
	at: number,
	seq: number,
	thread: thread,
	args: { any },
	argCount: number,
	-- true when resuming a thread that yielded in wait(); the resume value is the elapsed time.
	isWaitResume: boolean,
	waitStarted: number,
}

local Clock = {}

function Clock.new(options: Options?): Clock
	local opts: Options = options or {}
	local start = opts.start or 1_700_000_000
	local minWait = opts.minWait or 1 / 60

	local monotonic = 0
	local seq = 0
	local timers: { Timer } = {}
	local owned: { [thread]: boolean } = {}
	local cancelled: { [thread]: boolean } = {}
	local running = false

	local self = {} :: Clock

	local function insertTimer(timer: Timer)
		-- Keep sorted by (at, seq). Lists are small in tests; linear insert keeps it simple.
		local index = #timers + 1
		for i, other in timers do
			if timer.at < other.at or (timer.at == other.at and timer.seq < other.seq) then
				index = i
				break
			end
		end
		table.insert(timers, index, timer)
	end

	local function schedule(at: number, thread: thread, args: { any }, argCount: number, isWaitResume: boolean)
		seq += 1
		insertTimer({
			at = at,
			seq = seq,
			thread = thread,
			args = args,
			argCount = argCount,
			isWaitResume = isWaitResume,
			waitStarted = monotonic,
		})
	end

	local function toThread(fnOrThread: any): thread
		if type(fnOrThread) == "thread" then
			owned[fnOrThread] = true
			return fnOrThread
		end
		assert(type(fnOrThread) == "function", "task: expected a function or thread")
		local thread = coroutine.create(fnOrThread)
		owned[thread] = true
		return thread
	end

	local function resume(thread: thread, ...: any)
		if cancelled[thread] or coroutine.status(thread) == "dead" then
			return
		end
		local ok, err = coroutine.resume(thread, ...)
		if not ok then
			error(debug.traceback(thread, tostring(err)), 0)
		end
		if coroutine.status(thread) == "dead" then
			owned[thread] = nil
		end
	end

	local function runDue(target: number)
		assert(not running, "Clock: advance() called re-entrantly from a clock-run thread")
		running = true
		local ok, err = pcall(function()
			while timers[1] and timers[1].at <= target do
				local timer = table.remove(timers, 1) :: Timer
				if timer.at > monotonic then
					monotonic = timer.at
				end
				if timer.isWaitResume then
					resume(timer.thread, monotonic - timer.waitStarted)
				else
					resume(timer.thread, table.unpack(timer.args, 1, timer.argCount))
				end
			end
		end)
		running = false
		if target > monotonic then
			monotonic = target
		end
		if not ok then
			error(err, 0)
		end
	end

	function self.now(_self: Clock): number
		return start + monotonic
	end

	function self.clock(_self: Clock): number
		return monotonic
	end

	function self.advance(_self: Clock, seconds: number)
		assert(seconds >= 0, "Clock:advance expects a non-negative duration")
		runDue(monotonic + seconds)
	end

	function self.advanceTo(_self: Clock, target: number)
		assert(target >= monotonic, "Clock:advanceTo cannot go backwards")
		runDue(target)
	end

	function self.flush(_self: Clock)
		runDue(monotonic)
	end

	function self.pending(_self: Clock): number
		return #timers
	end

	function self.nextDeadline(_self: Clock): number?
		local first = timers[1]
		return if first then first.at else nil
	end

	local taskLib = {} :: TaskLib

	function taskLib.wait(seconds: number?): number
		local duration = math.max(seconds or 0, minWait)
		local current = coroutine.running()
		if owned[current] and coroutine.isyieldable() then
			schedule(monotonic + duration, current, {}, 0, true)
			return coroutine.yield()
		end
		-- Called from the test body: advance time synchronously.
		local before = monotonic
		runDue(monotonic + duration)
		return monotonic - before
	end

	function taskLib.spawn(fnOrThread: any, ...: any): thread
		local thread = toThread(fnOrThread)
		resume(thread, ...)
		return thread
	end

	function taskLib.defer(fnOrThread: any, ...: any): thread
		local thread = toThread(fnOrThread)
		schedule(monotonic, thread, table.pack(...), select("#", ...), false)
		return thread
	end

	function taskLib.delay(seconds: number?, fnOrThread: any, ...: any): thread
		local thread = toThread(fnOrThread)
		schedule(monotonic + math.max(seconds or 0, 0), thread, table.pack(...), select("#", ...), false)
		return thread
	end

	function taskLib.cancel(thread: thread)
		cancelled[thread] = true
		owned[thread] = nil
		for i = #timers, 1, -1 do
			if timers[i].thread == thread then
				table.remove(timers, i)
			end
		end
	end

	self.task = taskLib

	function self.wait(_self: Clock, seconds: number?): number
		return taskLib.wait(seconds)
	end

	function self.deps(_self: Clock): Deps
		return {
			now = function()
				return start + monotonic
			end,
			clock = function()
				return monotonic
			end,
			wait = function(seconds: number)
				taskLib.wait(seconds)
			end,
		}
	end

	return self
end

return Clock
