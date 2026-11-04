--!strict
--[[
	Gestures: turns raw pointer events (touch fingers, or the mouse as one finger) into the
	gestures a 3D editor needs: tap, long press, one-finger drag, and two-finger pinch with
	movement and twist (brief §7.3: drag-to-place, pinch-zoom, two-finger orbit, long-press for
	context). Pure: the game feeds positions and a clock and reads the events back, so the rules
	are tested under lune and every device behaves the same way.

		local gestures = UI.Gestures.new({ slop = 12 * scale })
		-- from UserInputService, per finger (input object as the id):
		handle(gestures:down(input, x, y, os.clock()))
		handle(gestures:move(input, x, y, os.clock()))
		handle(gestures:up(input, x, y, os.clock()))
		-- every frame, for long presses:
		handle(gestures:update(os.clock()))

	One finger. Lifted before moving more than `slop` pixels: "tap". Held still for `longPress`
	seconds: "longPress" once; lifting after that is not a tap. Moved past `slop`: "dragStart"
	(at the press point, `held` true after a long press), then "drag" with `dx`, `dy` since the
	last event, then "dragEnd" on release.

	Two fingers. The second finger turns the gesture into a pinch: a one-finger drag in progress
	ends with "dragCancel" first. Then "pinchStart", "pinch" on every move (`scale` is the finger
	distance now over the distance at the last event, `rotation` the twist in radians, `dx`, `dy`
	the midpoint's movement), and "pinchEnd" when either finger lifts. The finger left down never
	taps or drags, so a pinch can't end in a stray edit; putting a second finger back down starts
	a new pinch with it. Further fingers are ignored.

	`cancel()` ends whatever is in progress (dragCancel or pinchEnd) and forgets every pointer:
	call it when the view closes or loses input.
]]

export type Kind =
	"tap"
	| "longPress"
	| "dragStart"
	| "drag"
	| "dragEnd"
	| "dragCancel"
	| "pinchStart"
	| "pinch"
	| "pinchEnd"

export type Event = {
	kind: Kind,
	x: number, -- the finger, or the midpoint of two
	y: number,
	dx: number, -- movement since the previous event of this gesture
	dy: number,
	scale: number, -- pinch: distance ratio since the previous event (1 otherwise)
	rotation: number, -- pinch: twist since the previous event, radians (0 otherwise)
	held: boolean, -- a drag that began with a long press
	startX: number, -- where the gesture began
	startY: number,
}

export type Options = {
	slop: number?, -- pixels a finger may wander and still tap or long-press (default 12)
	longPress: number?, -- seconds (default 0.5)
}

export type Gestures = {
	down: (self: Gestures, id: any, x: number, y: number, now: number) -> { Event },
	move: (self: Gestures, id: any, x: number, y: number, now: number) -> { Event },
	up: (self: Gestures, id: any, x: number, y: number, now: number) -> { Event },
	update: (self: Gestures, now: number) -> { Event },
	cancel: (self: Gestures) -> { Event },
	-- "idle", "press" (one finger, not moved yet), "drag", "pinch" or "spent" (a finger left over
	-- from a pinch).
	state: (self: Gestures) -> string,
	count: (self: Gestures) -> number,
}

type Pointer = { x: number, y: number, startX: number, startY: number, t0: number }

local Gestures = {}

Gestures.DEFAULT_SLOP = 12
Gestures.DEFAULT_LONG_PRESS = 0.5

local function event(kind: Kind, x: number, y: number, startX: number, startY: number): Event
	return {
		kind = kind,
		x = x,
		y = y,
		dx = 0,
		dy = 0,
		scale = 1,
		rotation = 0,
		held = false,
		startX = startX,
		startY = startY,
	}
end

-- The smallest signed difference between two angles.
local function angleDelta(a: number, b: number): number
	local d = (a - b) % (2 * math.pi)
	if d > math.pi then
		d -= 2 * math.pi
	end
	return d
end

function Gestures.new(options: Options?): Gestures
	local o: Options = options or {}
	local slop = o.slop or Gestures.DEFAULT_SLOP
	local longPress = o.longPress or Gestures.DEFAULT_LONG_PRESS

	local pointers: { [any]: Pointer } = {}
	local count = 0
	local mode = "idle" -- idle | press | drag | pinch | spent
	local primary: any = nil
	local held = false
	-- Last reported one-finger position, and the pinch pair's last midpoint, distance and angle.
	local lastX, lastY = 0, 0
	local pairA: any, pairB: any = nil, nil
	local midX, midY, dist, angle = 0, 0, 1, 0
	local pinchStartX, pinchStartY = 0, 0

	local function pairGeometry(): (number, number, number, number)
		local a, b = pointers[pairA], pointers[pairB]
		local mx, my = (a.x + b.x) / 2, (a.y + b.y) / 2
		local vx, vy = b.x - a.x, b.y - a.y
		return mx, my, math.max(1e-3, math.sqrt(vx * vx + vy * vy)), math.atan2(vy, vx)
	end

	local function reset()
		mode, primary, held = "idle", nil, false
		pairA, pairB = nil, nil
	end

	local self = {}

	function self.down(_self: Gestures, id: any, x: number, y: number, now: number): { Event }
		local out: { Event } = {}
		if pointers[id] or count >= 2 then
			return out
		end
		pointers[id] = { x = x, y = y, startX = x, startY = y, t0 = now }
		count += 1
		if count == 1 then
			mode, primary, held = "press", id, false
			lastX, lastY = x, y
		else
			-- The other finger: pressing, dragging, or left over from a pinch (which resumes).
			local p = pointers[primary]
			if mode == "drag" then
				local e = event("dragCancel", p.x, p.y, p.startX, p.startY)
				e.held = held
				table.insert(out, e)
			end
			mode = "pinch"
			pairA, pairB = primary, id
			midX, midY, dist, angle = pairGeometry()
			pinchStartX, pinchStartY = midX, midY
			table.insert(out, event("pinchStart", midX, midY, midX, midY))
		end
		return out
	end

	function self.move(_self: Gestures, id: any, x: number, y: number, _now: number): { Event }
		local out: { Event } = {}
		local p = pointers[id]
		if p == nil then
			return out
		end
		p.x, p.y = x, y
		if mode == "press" and id == primary then
			local mx, my = x - p.startX, y - p.startY
			if mx * mx + my * my > slop * slop then
				mode = "drag"
				local start = event("dragStart", p.startX, p.startY, p.startX, p.startY)
				start.held = held
				table.insert(out, start)
				local e = event("drag", x, y, p.startX, p.startY)
				e.dx, e.dy, e.held = x - p.startX, y - p.startY, held
				table.insert(out, e)
				lastX, lastY = x, y
			end
		elseif mode == "drag" and id == primary then
			local e = event("drag", x, y, p.startX, p.startY)
			e.dx, e.dy, e.held = x - lastX, y - lastY, held
			table.insert(out, e)
			lastX, lastY = x, y
		elseif mode == "pinch" and (id == pairA or id == pairB) then
			local nx, ny, nd, na = pairGeometry()
			local e = event("pinch", nx, ny, pinchStartX, pinchStartY)
			e.dx, e.dy = nx - midX, ny - midY
			e.scale = nd / dist
			e.rotation = angleDelta(na, angle)
			table.insert(out, e)
			midX, midY, dist, angle = nx, ny, nd, na
		end
		return out
	end

	function self.up(_self: Gestures, id: any, x: number, y: number, _now: number): { Event }
		local out: { Event } = {}
		local p = pointers[id]
		if p == nil then
			return out
		end
		p.x, p.y = x, y
		if mode == "press" and id == primary then
			if not held then
				table.insert(out, event("tap", x, y, p.startX, p.startY))
			end
			reset()
		elseif mode == "drag" and id == primary then
			local e = event("dragEnd", x, y, p.startX, p.startY)
			e.dx, e.dy, e.held = x - lastX, y - lastY, held
			table.insert(out, e)
			reset()
		elseif mode == "pinch" and (id == pairA or id == pairB) then
			table.insert(out, event("pinchEnd", midX, midY, pinchStartX, pinchStartY))
			mode = "spent"
			primary = if id == pairA then pairB else pairA
			pairA, pairB = nil, nil
		end
		pointers[id] = nil
		count -= 1
		if count == 0 then
			reset()
		end
		return out
	end

	function self.update(_self: Gestures, now: number): { Event }
		local out: { Event } = {}
		if mode == "press" and not held then
			local p = pointers[primary]
			if p and now - p.t0 >= longPress then
				held = true
				local e = event("longPress", p.x, p.y, p.startX, p.startY)
				e.held = true
				table.insert(out, e)
			end
		end
		return out
	end

	function self.cancel(_self: Gestures): { Event }
		local out: { Event } = {}
		if mode == "drag" then
			local p = pointers[primary]
			local e = event("dragCancel", p.x, p.y, p.startX, p.startY)
			e.held = held
			table.insert(out, e)
		elseif mode == "pinch" then
			table.insert(out, event("pinchEnd", midX, midY, pinchStartX, pinchStartY))
		end
		table.clear(pointers)
		count = 0
		reset()
		return out
	end

	function self.state(_self: Gestures): string
		return mode
	end

	function self.count(_self: Gestures): number
		return count
	end

	return (self :: any) :: Gestures
end

return Gestures
