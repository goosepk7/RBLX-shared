--!strict
-- The event HUD chip on narrow phones and long translations: whatever the width, locale or
-- phase, the chip shows a form that fits (by the kit's text estimate) and still has the
-- countdown in it. Truncating "Corrida de Pernas de Pau: Começa em 4min 59s" at the end cut
-- the time off; the chip now drops the name, then the words, instead.
local Chip = require("@shared/UI/Kit/Chip")
local EventLobby = require("@shared/Screens/EventLobby")
local Layout = require("@shared/UI/Layout")
local Loc = require("@shared/Loc")
local Models = require("@shared/Screens/Models")
local Strings = require("@shared/Strings")
local T = require("@shared/Test")

local expect = T.expect

-- Long event names, the kind a game ships (Stilts' race and flood in Portuguese are the
-- longest so far).
local GAME = {
	en = { ["event.race"] = "Stilt Race", ["event.flood"] = "Flash Flood" },
	["pt-br"] = { ["event.race"] = "Corrida de Pernas de Pau", ["event.flood"] = "Enchente Relâmpago" },
	es = { ["event.race"] = "Carrera de Zancos Gigantes", ["event.flood"] = "Inundación Repentina" },
}
local LOCALES = { "en", "pt-br", "es" }
-- From the 120 px floor games give the chip up to a roomy tablet one.
local WIDTHS = { EventLobby.CHIP_MIN_WIDTH, 140, 160, 200, 260, 340 }
local PHASES = { "lobby", "warning", "running" }
local SECONDS = { 5, 42, 299, 599, 3599 }

local function newLoc(locale: string): Loc.Loc
	local loc = Loc.new({ tables = Loc.merge(Strings, GAME :: any) })
	loc:setLocale(locale)
	return loc
end

local function model(locale: string, phase: string, eventId: string, left: number): Models.EventModel
	return Models.event(newLoc(locale), { phase = phase, eventId = eventId, endsAt = left, participants = 1 }, 0)
end

-- English 30% longer stands in for a translation we haven't seen yet.
local function stretched(m: Models.EventModel): Models.EventModel
	local out = table.clone(m)
	local pad = function(s: string?): string?
		return if s then s .. string.rep("x", math.ceil((utf8.len(s) or #s) * 0.3)) else nil
	end
	out.eventName = pad(m.eventName)
	-- Pad the words, not the countdown.
	out.status = pad(m.status) :: string
	return out
end

T.describe("EventLobby chip text (narrow phones, long translations)", function()
	T.it("tries name + status, then status, then the countdown alone", function()
		local m = model("pt-br", "lobby", "race", 299)
		expect(EventLobby.chipTexts(m)).toEqual({
			"Corrida de Pernas de Pau: Começa em 4min 59s",
			"Começa em 4min 59s",
			"4:59",
		})
		-- A warning already names the event, so there is no "name: " form.
		expect(EventLobby.chipTexts(model("en", "warning", "flood", 42))).toEqual({
			"Flash Flood starts in 42s!",
			"0:42",
		})
		-- Idle has no countdown of its own to fall back to.
		local idle = Models.event(newLoc("en"), { phase = "idle", nextEventId = "race", endsAt = 90 }, 0)
		expect(EventLobby.chipTexts(idle)).toEqual({ "Next: Stilt Race in 1m 30s" })
	end)

	T.it("keeps the full text when the chip has no cap or room to spare", function()
		local m = model("en", "lobby", "race", 42)
		expect(EventLobby.chipText(m, nil)).toBe("Stilt Race: Starts in 42s")
		expect(EventLobby.chipText(m, 340)).toBe("Stilt Race: Starts in 42s")
	end)

	T.it("drops the name before the countdown on a narrow chip", function()
		local m = model("pt-br", "lobby", "race", 299)
		expect(EventLobby.chipText(m, 240)).toBe("Começa em 4min 59s")
		expect(EventLobby.chipText(m, EventLobby.CHIP_MIN_WIDTH)).toBe("4:59")
	end)

	T.it("always fits and always shows the countdown", function()
		local problems: { string } = {}
		for _, locale in LOCALES do
			for _, phase in PHASES do
				for _, eventId in { "race", "flood" } do
					for _, left in SECONDS do
						local base = model(locale, phase, eventId, left)
						local variants: { { label: string, m: Models.EventModel } } =
							{ { label = "", m = base }, { label = "+30%", m = stretched(base) } }
						for _, variant in variants do
							local m = variant.m
							for _, width in WIDTHS do
								local text = EventLobby.chipText(m, width)
								local room = Chip.labelWidth(width, true, false)
								local where = `{locale}{variant.label} {phase} {eventId} {left}s @{width}: "{text}"`
								if Chip.textWidth(text) > room then
									table.insert(
										problems,
										`too wide ({math.floor(Chip.textWidth(text))} > {room}) {where}`
									)
								end
								local clock = m.timeLeft :: string
								local duration = Models.duration(newLoc(locale), left)
								if not (string.find(text, clock, 1, true) or string.find(text, duration, 1, true)) then
									table.insert(problems, `no countdown {where}`)
								end
							end
						end
					end
				end
			end
		end
		expect(problems).toEqual({})
	end)

	T.it("an hour-plus countdown still fits from 140 px", function()
		local m = model("pt-br", "running", "race", 3 * 3600 + 5)
		expect(m.timeLeft).toBe("3:00:05")
		local text = EventLobby.chipText(m, 140)
		expect(text).toBe("3:00:05")
		expect(Chip.textWidth(text) <= Chip.labelWidth(140, true, false)).toBe(true)
	end)

	T.it("clock format", function()
		local loc = newLoc("en")
		expect(Models.clock(loc, 0)).toBe("0:00")
		expect(Models.clock(loc, 41.2)).toBe("0:42")
		expect(Models.clock(loc, 600)).toBe("10:00")
		expect(Models.clock(loc, 3661)).toBe("1:01:01")
		expect(Models.clock(loc, 2 * 86400 + 3 * 3600)).toBe("2d 3h")
		expect(Layout.textWidth("0:42", 16)).toBe(4 * 16 * Layout.TEXT_EM)
	end)
end)
