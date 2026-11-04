--!strict
--[[
	Tutorial overlay: coachmarks for onboarding (brief §5.5, §8). One step at a time: a gold
	ring around the thing to press (if the step has a target) and a bubble with the text, a
	step counter, Next (or Got it!) and Skip. The server's Tutorial module remembers how far
	the player got and reports each step to analytics, so a returning player picks up where
	they stopped and a finished tutorial never shows again.

	  local tutorial = Shared.Screens.Tutorial.start(env, {
	  	{ id = "move", textKey = "onboarding.move" },
	  	{ id = "openShop", textKey = "onboarding.shop", target = function() return hud.shopButton end, waits = true },
	  	{ id = "firstWin", textKey = "onboarding.win", waits = true },
	  })
	  -- Steps with `waits` finish when the game says the player did it:
	  tutorial.complete("openShop")

	Step ids must match the server's Tutorial.new({ steps }) list, in the same order. The
	overlay never blocks input outside its own buttons.
]]

local Create = require("../UI/Create")
local Kit = require("../UI/Kit")
local Models = require("./Models")
local Parts = require("./Parts")
local Tokens = require("../UI/Tokens")

export type Step = Models.TutorialStep & {
	-- The GuiObject to ring, looked up when the step shows (HUD buttons can be rebuilt).
	target: (() -> GuiObject?)?,
	-- True: the step ends when the game calls complete(id), not on Next.
	waits: boolean?,
}

export type Handle = {
	-- Finishes `stepId` (and any step before it) if it is the one showing or still ahead.
	complete: (stepId: string) -> (),
	-- The id of the step showing, if any.
	current: () -> string?,
	stop: () -> (),
}

local Tutorial = {}

local BUBBLE_WIDTH = 340

function Tutorial.start(env: Parts.Env, steps: { Step }, onFinished: ((skipped: boolean) -> ())?): Handle
	local loc = env.loc
	local remotes = env.remotes("Tutorial")
	local layer = env.area.modalLayer
	local overlay = Create.group({ Name = "Tutorial", ZIndex = 80, Parent = layer })
	local ring = Create.new("Frame", {
		Name = "Ring",
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 81,
		Parent = overlay,
	}, { Create.corner(Tokens.radius.card), Create.stroke("gold", 4) })
	local index = 0
	local stopped = false
	local bubble: Frame? = nil
	local watch: { RBXScriptConnection } = {}

	local function unwatch()
		for _, connection in watch do
			connection:Disconnect()
		end
		table.clear(watch)
	end

	local function place(target: GuiObject?)
		local scale = env.area.getScale()
		local origin = overlay.AbsolutePosition
		local b = bubble
		if target == nil or not target:IsDescendantOf(game) then
			ring.Visible = false
			if b then
				b.AnchorPoint = Vector2.new(0.5, 1)
				b.Position = UDim2.new(0.5, 0, 1, -Tokens.space.xxl)
			end
			return
		end
		local pad = Tokens.space.sm
		local pos = (target.AbsolutePosition - origin) / scale
		local size = target.AbsoluteSize / scale
		ring.Visible = true
		ring.Position = UDim2.fromOffset(pos.X - pad, pos.Y - pad)
		ring.Size = UDim2.fromOffset(size.X + pad * 2, size.Y + pad * 2)
		if b then
			local below = pos.Y + size.Y / 2 < (overlay.AbsoluteSize.Y / scale) / 2
			local x =
				math.clamp(pos.X + size.X / 2, BUBBLE_WIDTH / 2, overlay.AbsoluteSize.X / scale - BUBBLE_WIDTH / 2)
			b.AnchorPoint = Vector2.new(0.5, if below then 0 else 1)
			b.Position = UDim2.fromOffset(x, if below then pos.Y + size.Y + pad * 3 else pos.Y - pad * 3)
		end
	end

	local finish: (skipped: boolean) -> ()
	local show: (i: number) -> ()

	local function report(stepId: string)
		Parts.spawn(function()
			remotes.Step:invokeAsync(stepId)
		end)
	end

	local function advance()
		local step = steps[index]
		if step then
			report(step.id)
		end
		if index >= #steps then
			finish(false)
		else
			show(index + 1)
		end
	end

	function show(i: number)
		unwatch()
		if bubble then
			bubble:Destroy()
		end
		index = i
		local step = steps[i]
		local model = Models.tutorialStep(loc, steps, i)
		local root, card = Kit.Card.new({
			Variant = "Elevated",
			AutoHeight = true,
			Size = UDim2.fromOffset(BUBBLE_WIDTH, 0),
			ZIndex = 82,
			Parent = overlay,
		})
		bubble = root
		Create.list("Vertical", Tokens.space.sm, "Left", "Top").Parent = card.content
		Parts.text(card.content, 1, model.counter, { size = "caption", color = "inkSoft" })
		Parts.text(card.content, 2, model.text, { size = "body" })
		local row = Parts.stack(card.content, 3, "Horizontal", Tokens.space.sm)
		Kit.Button.new({
			Text = model.skip,
			Variant = "Ghost",
			Size = "Small",
			Width = 120,
			LayoutOrder = 1,
			Parent = row,
			OnActivated = function()
				finish(true)
			end,
		})
		if not step.waits then
			Kit.Button.new({
				Text = model.next,
				Variant = "Primary",
				Size = "Small",
				Width = 160,
				LayoutOrder = 2,
				Parent = row,
				OnActivated = advance,
			})
		end
		local target = if step.target then step.target() else nil
		place(target)
		if target then
			table.insert(
				watch,
				target:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
					place(target)
				end)
			)
			table.insert(
				watch,
				target:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
					place(target)
				end)
			)
		end
		table.insert(
			watch,
			overlay:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
				place(target)
			end)
		)
	end

	function finish(skipped: boolean)
		if stopped then
			return
		end
		stopped = true
		unwatch()
		overlay:Destroy()
		if skipped then
			Parts.spawn(function()
				remotes.Skip:invokeAsync()
			end)
		end
		if onFinished then
			onFinished(skipped)
		end
	end

	-- Resume where the server says this player is; nothing shows if they're done.
	Parts.spawn(function()
		local result = remotes.GetState:invokeAsync()
		if stopped then
			return
		end
		local status = if result.ok then result.value else nil
		if status == nil or status.done then
			stopped = true
			overlay:Destroy()
			return
		end
		local start = 1
		for i, step in steps do
			if step.id == status.next then
				start = i
			end
		end
		show(start)
	end)

	return {
		complete = function(stepId: string)
			if stopped then
				return
			end
			local target: number? = nil
			for i, step in steps do
				if step.id == stepId then
					target = i
				end
			end
			if target == nil then
				return
			end
			if index == 0 then
				-- Still loading: the server learns of it and the overlay resumes past it.
				report(stepId)
				return
			end
			if target < index then
				return
			end
			index = target
			advance()
		end,
		current = function(): string?
			local step = steps[index]
			return if step and not stopped then step.id else nil
		end,
		stop = function()
			if not stopped then
				stopped = true
				unwatch()
				overlay:Destroy()
			end
		end,
	}
end

return Tutorial
