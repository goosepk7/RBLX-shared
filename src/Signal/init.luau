--!strict
--[[
	Signal: a pure-Luau event with the same surface as RBXScriptSignal.

	  local Changed = Signal.new() :: Signal.Signal<Player, number>
	  local connection = Changed:Connect(function(player, value) ... end)
	  Changed:Fire(player, 10)
	  connection:Disconnect()

	Semantics (match Roblox's immediate signal behaviour):
	  * Handlers run in connection order, each on its own thread (task.spawn in Roblox), so a
	    handler that yields does not block Fire or the other handlers.
	  * An error in one handler is reported (red in Output, with its traceback) and does not stop
	    the others. Nothing is swallowed.
	  * Connecting or disconnecting while firing is safe: Fire works on a snapshot.
	  * Wait() yields the calling thread until the next Fire and returns its arguments.
]]

local Log = require("./Util/Log")

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
	Destroy: (self: Signal<T...>) -> (),
	-- Number of live connections (diagnostics and tests).
	connectionCount: (self: Signal<T...>) -> number,
}

type Slot = {
	handler: (...any) -> (),
	connection: Connection,
	once: boolean,
}

local Signal = {}

-- Runs `handler(...)` on a new thread. Uses task.spawn inside Roblox; under lune (no task
-- library) resumes a coroutine directly and reports errors through Log.
local function spawnHandler(handler: (...any) -> (), ...: any)
	local taskLib = task :: any
	if taskLib ~= nil then
		taskLib.spawn(handler, ...)
		return
	end
	local thread = coroutine.create(handler)
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		Log.error("Signal", "handler errored: " .. debug.traceback(thread, tostring(err)))
	end
end

local function resumeThread(thread: thread, ...: any)
	local taskLib = task :: any
	if taskLib ~= nil then
		taskLib.spawn(thread, ...)
		return
	end
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		Log.error("Signal", "thread resumed by Wait errored: " .. debug.traceback(thread, tostring(err)))
	end
end

function Signal.new<T...>(): Signal<T...>
	local slots: { Slot } = {}
	local destroyed = false

	local function connect(handler: (...any) -> (), once: boolean): Connection
		assert(type(handler) == "function", "Signal:Connect expects a function")
		local connection = {} :: Connection
		connection.Connected = not destroyed
		function connection.Disconnect(self: Connection)
			if not self.Connected then
				return
			end
			self.Connected = false
			for index, slot in slots do
				if slot.connection == self then
					table.remove(slots, index)
					break
				end
			end
		end
		if not destroyed then
			table.insert(slots, { handler = handler, connection = connection, once = once })
		end
		return connection
	end

	local signal = {} :: Signal<T...>

	function signal.Connect(_self: Signal<T...>, handler: (T...) -> ()): Connection
		return connect(handler :: any, false)
	end

	function signal.Once(_self: Signal<T...>, handler: (T...) -> ()): Connection
		return connect(handler :: any, true)
	end

	function signal.Wait(_self: Signal<T...>): T...
		local thread = coroutine.running()
		connect(function(...: any)
			resumeThread(thread, ...)
		end, true)
		return coroutine.yield()
	end

	function signal.Fire(_self: Signal<T...>, ...: T...)
		if #slots == 0 then
			return
		end
		local snapshot = table.clone(slots)
		for _, slot in snapshot do
			if slot.connection.Connected then
				if slot.once then
					slot.connection:Disconnect()
				end
				spawnHandler(slot.handler, ...)
			end
		end
	end

	function signal.DisconnectAll(_self: Signal<T...>)
		for _, slot in table.clone(slots) do
			slot.connection:Disconnect()
		end
	end

	function signal.Destroy(self: Signal<T...>)
		self:DisconnectAll()
		destroyed = true
	end

	function signal.connectionCount(_self: Signal<T...>): number
		return #slots
	end

	return signal
end

return Signal
