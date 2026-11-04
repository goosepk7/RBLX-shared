--!strict
local Deep = require("@shared/Util/Deep")
local Log = require("@shared/Util/Log")
local Net = require("@shared/Net")
local T = require("@shared/Test")

local S = Net.Schema
local expect = T.expect

-- Minimal MessagingService: synchronous delivery to every subscriber of a topic.
local function fakeMessaging(): any
	local subscribers: { [string]: { (any) -> () } } = {}
	local service = { published = 0, failPublish = false }
	function service.SubscribeAsync(_self: any, topic: string, callback: (any) -> ())
		local list = subscribers[topic] or {}
		subscribers[topic] = list
		table.insert(list, callback)
		return {
			Disconnect = function()
				local index = table.find(list, callback)
				if index then
					table.remove(list, index)
				end
			end,
		}
	end
	function service.PublishAsync(self: any, topic: string, data: any)
		if self.failPublish then
			error("MessagingService unavailable")
		end
		self.published += 1
		local list: { (any) -> () } = subscribers[topic] or {}
		for _, callback in table.clone(list) do
			callback({ Data = Deep.copy(data), Sent = 0 })
		end
	end
	return service
end

type Server = { context: Net.Context, switch: Net.KillSwitch }

local function newServer(clock: any, dss: any, messaging: any): Server
	local loop = Net.Loopback.new()
	local context = Net.newContext({
		side = "server",
		transport = loop.server,
		task = clock.task,
		now = function()
			return clock:now()
		end,
	})
	Net.namespace("Test", { Lunge = Net.clientEvent(S.number()) }, { context = context })
	local switch = Net.KillSwitch.new({
		context = context,
		dataStoreService = dss,
		messagingService = messaging,
	})
	return { context = context, switch = switch }
end

T.describe("Net.KillSwitch", function()
	local restoreLog: () -> ()

	T.beforeEach(function()
		local _, restore = Log.capture()
		restoreLog = restore
	end)

	T.afterEach(function()
		restoreLog()
	end)

	T.it("turns a remote off on every running server", function()
		local clock = T.Clock.new()
		local dss = T.Fakes.DataStoreService.new()
		local messaging = fakeMessaging()
		local a = newServer(clock, dss, messaging)
		local b = newServer(clock, dss, messaging)
		a.switch:startAsync()
		b.switch:startAsync()

		local ok = a.switch:setEnabledAsync("Test.Lunge", false, "exploit")
		expect(ok).toBe(true)
		expect(a.context:isEnabled("Test.Lunge")).toBe(false)
		expect(b.context:isEnabled("Test.Lunge")).toBe(false)
		expect(b.context:getDisabled()["Test.Lunge"].reason).toBe("exploit")

		a.switch:setEnabledAsync("Test.Lunge", true)
		expect(b.context:isEnabled("Test.Lunge")).toBe(true)
	end)

	T.it("servers that start later load the persisted state", function()
		local clock = T.Clock.new()
		local dss = T.Fakes.DataStoreService.new()
		local messaging = fakeMessaging()
		local a = newServer(clock, dss, messaging)
		a.switch:startAsync()
		a.switch:setEnabledAsync("Test.*", false, "maintenance")

		local late = newServer(clock, dss, messaging)
		expect(late.context:isEnabled("Test.Lunge")).toBe(true)
		late.switch:startAsync()
		expect(late.context:isEnabled("Test.Lunge")).toBe(false)
		expect(late.switch:getState().version).toBe(1)
	end)

	T.it("servers that miss the ping converge on the next poll", function()
		local clock = T.Clock.new()
		local dss = T.Fakes.DataStoreService.new()
		local messaging = fakeMessaging()
		local a = newServer(clock, dss, messaging)
		local deaf = newServer(clock, dss, false)
		a.switch:startAsync()
		deaf.switch:startAsync()
		a.switch:setEnabledAsync("Test.Lunge", false)
		expect(deaf.context:isEnabled("Test.Lunge")).toBe(true)
		clock:advance(300)
		expect(deaf.context:isEnabled("Test.Lunge")).toBe(false)
		deaf.switch:stop()
		a.switch:stop()
		expect(clock:pending()).toBe(0)
	end)

	T.it("keeps working when the ping fails, and reports a failed write", function()
		local clock = T.Clock.new()
		local dss = T.Fakes.DataStoreService.new()
		local messaging = fakeMessaging()
		local a = newServer(clock, dss, messaging)
		a.switch:startAsync()
		messaging.failPublish = true
		expect((a.switch:setEnabledAsync("Test.Lunge", false))).toBe(true)
		expect(a.context:isEnabled("Test.Lunge")).toBe(false)

		dss:failNext("UpdateAsync", { code = 502 })
		local ok, err = a.switch:setEnabledAsync("Test.Lunge", true)
		expect(ok).toBe(false)
		expect(err).toContain("502")
		expect(a.context:isEnabled("Test.Lunge")).toBe(false)
	end)

	T.it("ignores stale versions", function()
		local clock = T.Clock.new()
		local dss = T.Fakes.DataStoreService.new()
		local a = newServer(clock, dss, false)
		a.context:applyGlobalState({ version = 5, disabled = { ["Test.Lunge"] = { reason = "x", at = 0 } } })
		a.context:applyGlobalState({ version = 4, disabled = {} })
		expect(a.context:isEnabled("Test.Lunge")).toBe(false)
	end)

	T.it("local switches and the global layer are independent", function()
		local clock = T.Clock.new()
		local dss = T.Fakes.DataStoreService.new()
		local a = newServer(clock, dss, false)
		a.context:setEnabled("Test.Lunge", false, "local")
		a.context:applyGlobalState({ version = 1, disabled = {} })
		expect(a.context:isEnabled("Test.Lunge")).toBe(false)
		a.context:setEnabled("Test.Lunge", true)
		expect(a.context:isEnabled("Test.Lunge")).toBe(true)
	end)
end)
