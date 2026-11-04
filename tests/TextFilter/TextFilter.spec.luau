--!strict
local T = require("@shared/Test")
local TextFilter = require("@shared/TextFilter")

local expect = T.expect

-- A stand-in for TextService: hashes every "bad", can be told to fail the next `failures` calls.
local function fakeBackend(): (TextFilter.Backend, { calls: number, failures: number, users: { number } })
	local state = { calls = 0, failures = 0, users = {} :: { number } }
	local function backend(text: string, fromUserId: number): string
		state.calls += 1
		table.insert(state.users, fromUserId)
		if state.failures > 0 then
			state.failures -= 1
			error("HTTP 503 (Service Unavailable)")
		end
		return (string.gsub(text, "bad", "###"))
	end
	return backend, state
end

local function noWait(_seconds: number) end

T.describe("TextFilter.clean", function()
	T.it("trims and collapses whitespace", function()
		expect(TextFilter.clean("  Mud   Crawler  ")).toBe("Mud Crawler")
		expect(TextFilter.clean("Tab\tand\nnewline")).toBe("Tab and newline")
		expect(TextFilter.clean("   ")).toBe("")
	end)

	T.it("drops control and invisible characters and invalid UTF-8", function()
		expect(TextFilter.clean("Zero\u{200B}Width")).toBe("ZeroWidth")
		expect(TextFilter.clean("\u{202E}Flipped")).toBe("Flipped")
		expect(TextFilter.clean("Bell\7 and DEL\127")).toBe("Bell and DEL")
		expect(TextFilter.clean("Bad\255byte")).toBe("Badbyte")
		expect(TextFilter.clean("\u{FEFF}Car")).toBe("Car")
	end)

	T.it("caps at a number of characters, not bytes", function()
		expect(TextFilter.clean("Carro Rápido", 7)).toBe("Carro R")
		expect((utf8.len(TextFilter.clean("ñññññññññññ", 4)))).toBe(4)
		expect(TextFilter.clean("abc", 3)).toBe("abc")
		-- A space that would leave no room for the next character is dropped, not kept dangling.
		expect(TextFilter.clean("abc def", 4)).toBe("abc")
	end)

	T.it("keeps letters from any script", function()
		expect(TextFilter.clean("Ônibus 2", 20)).toBe("Ônibus 2")
		expect(TextFilter.clean("Машина", 20)).toBe("Машина")
	end)
end)

T.describe("TextFilter.new", function()
	T.it("returns the filtered text and asks as the given user", function()
		local backend, state = fakeBackend()
		local filter = TextFilter.new({ backend = backend, wait = noWait })
		local text, failure = filter:broadcast("bad wheels", 42)
		expect(text).toBe("### wheels")
		expect(failure).toBeNil()
		expect(state.users).toEqual({ 42 })
	end)

	T.it("retries a failing service, then succeeds", function()
		local backend, state = fakeBackend()
		state.failures = 2
		local waits: { number } = {}
		local filter = TextFilter.new({
			backend = backend,
			retries = 2,
			retryDelay = 0.25,
			wait = function(s: number)
				table.insert(waits, s)
			end,
		})
		expect((filter:broadcast("ok", 1))).toBe("ok")
		expect(state.calls).toBe(3)
		expect(waits).toEqual({ 0.25, 0.25 })
	end)

	T.it("fails closed when the service keeps failing", function()
		local backend, state = fakeBackend()
		state.failures = 10
		local filter = TextFilter.new({ backend = backend, retries = 2, wait = noWait })
		local text, failure = filter:broadcast("anything", 1)
		expect(text).toBeNil()
		expect(failure).toBe("unavailable")
		expect(state.calls).toBe(3)
	end)

	T.it("fails closed when the backend returns something that isn't text", function()
		local filter = TextFilter.new({
			backend = function(_text: string, _userId: number): string
				return (nil :: any) :: string
			end,
			retries = 0,
			wait = noWait,
		})
		expect(select(2, filter:broadcast("x", 1))).toBe("unavailable")
	end)

	T.it("caches per user and text until it expires", function()
		local backend, state = fakeBackend()
		local clock = 0
		local filter = TextFilter.new({
			backend = backend,
			cacheSeconds = 10,
			wait = noWait,
			now = function(): number
				return clock
			end,
		})
		filter:broadcast("Starter", 1)
		filter:broadcast("Starter", 1)
		expect(state.calls).toBe(1)
		filter:broadcast("Starter", 2) -- another player typing the same text asks again
		expect(state.calls).toBe(2)
		clock = 11
		filter:broadcast("Starter", 1)
		expect(state.calls).toBe(3)
	end)

	T.it("keeps the cache bounded", function()
		local backend, state = fakeBackend()
		local filter = TextFilter.new({ backend = backend, cacheSize = 4, wait = noWait })
		for i = 1, 20 do
			filter:broadcast("name " .. i, 1)
		end
		expect(state.calls).toBe(20)
		filter:broadcast("name 20", 1) -- still cached: the newest entries survive a flush
		expect(state.calls).toBe(20)
	end)

	T.it("doesn't call the service for empty text", function()
		local backend, state = fakeBackend()
		local filter = TextFilter.new({ backend = backend, wait = noWait })
		expect((filter:broadcast("", 1))).toBe("")
		expect(state.calls).toBe(0)
	end)
end)
