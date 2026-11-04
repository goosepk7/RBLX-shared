--!strict
local Gestures = require("@shared/UI/Gestures")
local T = require("@shared/Test")

local expect = T.expect

local function kinds(events: { Gestures.Event }): { string }
	local out: { string } = {}
	for _, e in events do
		table.insert(out, e.kind)
	end
	return out
end

-- Collects every event a script of calls produces.
local function run(steps: { () -> { Gestures.Event } }): { Gestures.Event }
	local all: { Gestures.Event } = {}
	for _, step in steps do
		for _, e in step() do
			table.insert(all, e)
		end
	end
	return all
end

T.describe("UI.Gestures: one finger", function()
	T.it("taps when lifted without moving past the slop", function()
		local g = Gestures.new({ slop = 10 })
		local events = run({
			function()
				return g:down(1, 100, 100, 0)
			end,
			function()
				return g:move(1, 106, 104, 0.05)
			end,
			function()
				return g:up(1, 106, 104, 0.1)
			end,
		})
		expect(kinds(events)).toEqual({ "tap" })
		expect(events[1].x).toBe(106)
		expect(events[1].startX).toBe(100)
		expect(g:state()).toBe("idle")
		expect(g:count()).toBe(0)
	end)

	T.it("drags once past the slop, reporting movement since the last event", function()
		local g = Gestures.new({ slop = 10 })
		local events = run({
			function()
				return g:down(1, 100, 100, 0)
			end,
			function()
				return g:move(1, 115, 100, 0.1)
			end,
			function()
				return g:move(1, 120, 90, 0.2)
			end,
			function()
				return g:up(1, 121, 90, 0.3)
			end,
		})
		expect(kinds(events)).toEqual({ "dragStart", "drag", "drag", "dragEnd" })
		expect(events[1].x).toBe(100) -- dragStart is at the press point
		expect({ events[2].dx, events[2].dy }).toEqual({ 15, 0 })
		expect({ events[3].dx, events[3].dy }).toEqual({ 5, -10 })
		expect({ events[4].x, events[4].dx }).toEqual({ 121, 1 })
		expect(events[2].held).toBe(false)
	end)

	T.it("long-presses once when held still, and then isn't a tap", function()
		local g = Gestures.new({ slop = 10, longPress = 0.5 })
		g:down(1, 50, 50, 0)
		expect(#g:update(0.3)).toBe(0)
		local held = g:update(0.5)
		expect(kinds(held)).toEqual({ "longPress" })
		expect(held[1].x).toBe(50)
		expect(#g:update(0.9)).toBe(0) -- once
		expect(#g:up(1, 50, 50, 1)).toBe(0)
	end)

	T.it("drags after a long press with held set (pick up and move)", function()
		local g = Gestures.new({ slop = 10, longPress = 0.5 })
		g:down(1, 50, 50, 0)
		g:update(0.6)
		local events = g:move(1, 80, 50, 0.7)
		expect(kinds(events)).toEqual({ "dragStart", "drag" })
		expect(events[1].held).toBe(true)
		expect(events[2].held).toBe(true)
		expect(g:up(1, 80, 50, 0.8)[1].held).toBe(true)
	end)

	T.it("doesn't long-press a finger that started dragging", function()
		local g = Gestures.new({ slop = 10, longPress = 0.5 })
		g:down(1, 0, 0, 0)
		g:move(1, 30, 0, 0.1)
		expect(#g:update(2)).toBe(0)
	end)
end)

T.describe("UI.Gestures: two fingers", function()
	T.it("pinches with scale, midpoint movement and twist", function()
		local g = Gestures.new({ slop = 10 })
		g:down("a", 100, 100, 0)
		local start = g:down("b", 200, 100, 0.02)
		expect(kinds(start)).toEqual({ "pinchStart" })
		expect({ start[1].x, start[1].y }).toEqual({ 150, 100 })
		-- Spread to twice the distance, one finger at a time: each move is its own event.
		local first = g:move("a", 50, 100, 0.1)[1]
		expect(first.kind).toBe("pinch")
		expect(first.scale).toBeNear(150 / 100, 1e-9)
		expect(first.dx).toBeNear(-25, 1e-9)
		local second = g:move("b", 250, 100, 0.1)[1]
		expect(second.scale).toBeNear(200 / 150, 1e-9)
		expect(second.dx).toBeNear(25, 1e-9)
		-- Both fingers slide down 20: over the two events, pure movement with no scale or twist.
		local s1 = g:move("a", 50, 120, 0.2)[1]
		local s2 = g:move("b", 250, 120, 0.2)[1]
		expect(s1.dy + s2.dy).toBeNear(20, 1e-9)
		expect(s1.scale * s2.scale).toBeNear(1, 1e-9)
		expect(s1.rotation + s2.rotation).toBeNear(0, 1e-9)
		expect(s2.x).toBe(150)
		expect(s2.startX).toBe(150)
		expect(g:state()).toBe("pinch")
	end)

	T.it("reports a twist as a signed angle", function()
		local g = Gestures.new()
		g:down(1, 0, 0, 0)
		g:down(2, 100, 0, 0)
		local e = g:move(2, 0, 100, 0.1)[1] -- a quarter turn clockwise on screen (y down)
		expect(e.rotation).toBeNear(math.pi / 2, 1e-9)
		e = g:move(2, 100, 0, 0.2)[1]
		expect(e.rotation).toBeNear(-math.pi / 2, 1e-9)
		-- Crossing the ±180° seam stays small.
		g:move(2, -100, 1, 0.3)
		e = g:move(2, -100, -1, 0.4)[1]
		expect(math.abs(e.rotation) < 0.1).toBe(true)
	end)

	T.it("cancels a one-finger drag when a second finger lands", function()
		local g = Gestures.new({ slop = 10 })
		g:down(1, 0, 0, 0)
		g:move(1, 40, 0, 0.1)
		expect(kinds(g:down(2, 100, 0, 0.2))).toEqual({ "dragCancel", "pinchStart" })
	end)

	T.it("ends the pinch when a finger lifts, and the other finger never taps or drags", function()
		local g = Gestures.new({ slop = 10, longPress = 0.5 })
		g:down(1, 0, 0, 0)
		g:down(2, 100, 0, 0)
		expect(kinds(g:up(2, 100, 0, 0.1))).toEqual({ "pinchEnd" })
		expect(g:state()).toBe("spent")
		expect(#g:move(1, 300, 300, 0.2)).toBe(0)
		expect(#g:update(5)).toBe(0)
		expect(#g:up(1, 300, 300, 5)).toBe(0)
		expect(g:state()).toBe("idle")
		-- A fresh finger works normally again.
		g:down(3, 10, 10, 6)
		expect(kinds(g:up(3, 10, 10, 6.1))).toEqual({ "tap" })
	end)

	T.it("resumes a pinch when a finger goes back down", function()
		local g = Gestures.new()
		g:down(1, 0, 0, 0)
		g:down(2, 100, 0, 0)
		g:up(2, 100, 0, 0.1)
		local again = g:down(3, 0, 80, 0.2)
		expect(kinds(again)).toEqual({ "pinchStart" })
		expect({ again[1].x, again[1].y }).toEqual({ 0, 40 })
		local e = g:move(3, 0, 160, 0.3)[1]
		expect(e.scale).toBeNear(2, 1e-9)
	end)

	T.it("ignores a third finger", function()
		local g = Gestures.new()
		g:down(1, 0, 0, 0)
		g:down(2, 100, 0, 0)
		expect(#g:down(3, 50, 50, 0)).toBe(0)
		expect(#g:move(3, 60, 60, 0.1)).toBe(0)
		expect(#g:up(3, 60, 60, 0.2)).toBe(0)
		expect(g:count()).toBe(2)
		expect(g:state()).toBe("pinch")
	end)
end)

T.describe("UI.Gestures: cancel", function()
	T.it("ends a drag or a pinch and forgets every finger", function()
		local g = Gestures.new({ slop = 5 })
		g:down(1, 0, 0, 0)
		g:move(1, 20, 0, 0.1)
		expect(kinds(g:cancel())).toEqual({ "dragCancel" })
		expect(g:count()).toBe(0)
		expect(#g:up(1, 20, 0, 0.2)).toBe(0) -- the old finger is gone
		g:down(1, 0, 0, 1)
		g:down(2, 10, 0, 1)
		expect(kinds(g:cancel())).toEqual({ "pinchEnd" })
		g:down(5, 0, 0, 2)
		expect(#g:cancel()).toBe(0) -- a press that hasn't become anything ends quietly
		expect(g:state()).toBe("idle")
	end)
end)
