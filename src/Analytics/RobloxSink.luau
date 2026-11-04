--!strict
--[[
	Sends Analytics events to Roblox's AnalyticsService (Creator Hub > Analytics).

	Each event kind maps to one AnalyticsService method. Enum values are read when an event is
	sent, never at require time, so this module loads under lune; tests pass a fake service and
	a fake `enum` table.

	Custom fields: Roblox keeps up to three per event, keyed CustomField01..03. Analytics passes
	them as a map; they are sent in sorted key order, so keep the same keys for the same event
	or the dashboard columns shift.
]]

local Roblox = require("../Util/Roblox")

export type Event = {
	kind: "custom" | "onboarding" | "funnel" | "progression" | "economy",
	at: number,
	userId: number,
	name: string,
	value: number?,
	step: number?,
	stepName: string?,
	funnelSession: string?,
	status: ("start" | "complete" | "fail")?,
	level: number?,
	levelName: string?,
	flow: ("source" | "sink")?,
	currency: string?,
	amount: number?,
	balance: number?,
	transactionType: string?,
	sku: string?,
	fields: { [string]: string }?,
}

-- Sends one event for `player`. Errors propagate: Analytics counts and reports them.
export type Sink = (player: any, event: Event) -> ()

local RobloxSink = {}

RobloxSink.MAX_FIELDS = 3

local FIELD_KEYS = { "CustomField01", "CustomField02", "CustomField03" }

function RobloxSink.fieldsFor(fields: { [string]: string }?, enum: any): { [string]: string }?
	if fields == nil then
		return nil
	end
	local keys: { string } = {}
	for key in fields do
		table.insert(keys, key)
	end
	if #keys == 0 then
		return nil
	end
	table.sort(keys)
	local out: { [string]: string } = {}
	for i = 1, math.min(#keys, RobloxSink.MAX_FIELDS) do
		local enumItem = enum.AnalyticsCustomFieldKeys[FIELD_KEYS[i]]
		out[enumItem.Name] = fields[keys[i]]
	end
	return out
end

--- A sink over `service` (default: AnalyticsService) and `enum` (default: Enum).
function RobloxSink.new(service: any?, enum: any?): Sink
	local analyticsService: any = service
	local enums: any = enum
	return function(player: any, event: Event)
		analyticsService = analyticsService or Roblox.service("AnalyticsService")
		enums = enums or Roblox.enum()
		local fields = RobloxSink.fieldsFor(event.fields, enums)
		local kind = event.kind
		if kind == "custom" then
			analyticsService:LogCustomEvent(player, event.name, event.value or 1, fields)
		elseif kind == "onboarding" then
			analyticsService:LogOnboardingFunnelStepEvent(player, event.step, event.stepName, fields)
		elseif kind == "funnel" then
			analyticsService:LogFunnelStepEvent(
				player,
				event.name,
				event.funnelSession,
				event.step,
				event.stepName,
				fields
			)
		elseif kind == "progression" then
			local status = event.status
			if status == "start" then
				analyticsService:LogProgressionStartEvent(player, event.name, event.level, event.levelName, fields)
			elseif status == "complete" then
				analyticsService:LogProgressionCompleteEvent(player, event.name, event.level, event.levelName, fields)
			else
				analyticsService:LogProgressionFailEvent(player, event.name, event.level, event.levelName, fields)
			end
		elseif kind == "economy" then
			local flow = if event.flow == "sink"
				then enums.AnalyticsEconomyFlowType.Sink
				else enums.AnalyticsEconomyFlowType.Source
			analyticsService:LogEconomyEvent(
				player,
				flow,
				event.currency,
				event.amount,
				event.balance,
				event.transactionType,
				event.sku,
				fields
			)
		else
			error("RobloxSink: unknown event kind " .. tostring(kind))
		end
	end
end

return RobloxSink
