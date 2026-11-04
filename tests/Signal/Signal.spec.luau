--!strict
local Log = require("@shared/Util/Log")
local Signal = require("@shared/Signal")
local T = require("@shared/Test")

local expect = T.expect

T.describe("Signal", function()
	T.it("calls handlers in connection order with the fired arguments", function()
		local signal = Signal.new() :: Signal.Signal<string, number>
		local calls: { string } = {}
		signal:Connect(function(name, value)
			table.insert(calls, "a:" .. name .. value)
		end)
		signal:Connect(function(name, value)
			table.insert(calls, "b:" .. name .. value)
		end)
		signal:Fire("x", 1)
		expect(calls).toEqual({ "a:x1", "b:x1" })
	end)

	T.it("Disconnect and Once", function()
		local signal = Signal.new() :: Signal.Signal<>
		local count = 0
		local connection = signal:Connect(function()
			count += 1
		end)
		signal:Once(function()
			count += 10
		end)
		signal:Fire()
		connection:Disconnect()
		signal:Fire()
		expect(count).toBe(11)
		expect(connection.Connected).toBe(false)
		expect(signal:connectionCount()).toBe(0)
	end)

	T.it("reports a failing handler and still runs the others", function()
		local signal = Signal.new() :: Signal.Signal<>
		local ran = false
		local entries, restore = Log.capture()
		signal:Connect(function()
			error("boom")
		end)
		signal:Connect(function()
			ran = true
		end)
		signal:Fire()
		restore()
		expect(ran).toBe(true)
		expect(#entries).toBe(1)
		expect(entries[1].level).toBe("error")
		expect(entries[1].message).toContain("boom")
	end)

	T.it("is safe to disconnect while firing", function()
		local signal = Signal.new() :: Signal.Signal<>
		local second = 0
		local first: Signal.Connection
		first = signal:Connect(function()
			first:Disconnect()
		end)
		signal:Connect(function()
			second += 1
		end)
		signal:Fire()
		signal:Fire()
		expect(second).toBe(2)
	end)

	T.it("Wait resumes the waiting thread with the fired values", function()
		local signal = Signal.new() :: Signal.Signal<number>
		local received: number? = nil
		local thread = coroutine.create(function()
			received = signal:Wait()
		end)
		coroutine.resume(thread)
		expect(received).toBeNil()
		signal:Fire(42)
		expect(received).toBe(42)
		expect(coroutine.status(thread)).toBe("dead")
	end)

	T.it("Destroy disconnects everything and ignores later connects", function()
		local signal = Signal.new() :: Signal.Signal<>
		local count = 0
		signal:Connect(function()
			count += 1
		end)
		signal:Destroy()
		local late = signal:Connect(function()
			count += 1
		end)
		signal:Fire()
		expect(count).toBe(0)
		expect(late.Connected).toBe(false)
	end)
end)
