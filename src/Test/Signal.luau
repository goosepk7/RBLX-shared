--!strict
--[[
	Minimal synchronous signal used by the fakes. Mirrors the RBXScriptSignal surface the
	framework relies on (Connect, Once, and a Connection with Disconnect/Connected).
	Handlers run synchronously, in connection order, when Fire is called.
]]

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
	ConnectionCount: (self: Signal<T...>) -> number,
}

type Slot = { handler: (...any) -> (), connection: Connection, once: boolean }

local Signal = {}

function Signal.new<T...>(): Signal<T...>
	local slots: { Slot } = {}

	local function connect(handler: (...any) -> (), once: boolean): Connection
		local connection = {} :: Connection
		connection.Connected = true
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
		table.insert(slots, { handler = handler, connection = connection, once = once })
		return connection
	end

	local signal = {} :: Signal<T...>

	function signal.Connect(_self: Signal<T...>, handler: (T...) -> ()): Connection
		return connect(handler :: any, false)
	end

	function signal.Once(_self: Signal<T...>, handler: (T...) -> ()): Connection
		return connect(handler :: any, true)
	end

	function signal.Fire(_self: Signal<T...>, ...: T...)
		-- Snapshot so handlers may connect/disconnect while firing.
		local snapshot = table.clone(slots)
		for _, slot in snapshot do
			if slot.connection.Connected then
				if slot.once then
					slot.connection:Disconnect()
				end
				slot.handler(...)
			end
		end
	end

	function signal.DisconnectAll(_self: Signal<T...>)
		for _, slot in table.clone(slots) do
			slot.connection:Disconnect()
		end
	end

	function signal.ConnectionCount(_self: Signal<T...>): number
		return #slots
	end

	return signal
end

return Signal
