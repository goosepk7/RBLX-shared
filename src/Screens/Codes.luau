--!strict
--[[
	Codes screen (brief §5.5): one field, one Redeem button, and the result on the field itself
	(TextInput Success or Danger with the reward or the reason). Codes are typed upper-case;
	the server normalizes again and decides.
]]

local Kit = require("../UI/Kit")
local Models = require("./Models")
local Parts = require("./Parts")
local ScreenManager = require("../UI/ScreenManager")

local CodesScreen = {}

function CodesScreen.build(env: Parts.Env, ctx: ScreenManager.ScreenContext): ScreenManager.Screen
	local loc = env.loc
	local remotes = env.remotes("Codes")
	local root, panel = Parts.panel(ctx, loc:t("codes.title"), "icon_codes", {
		footer = true,
		size = UDim2.new(0.92, 0, 0, 340),
	})
	local redeem: (text: string) -> ()
	local inputRoot, input = Kit.TextInput.new({
		Placeholder = loc:t("codes.placeholder"),
		Icon = "icon_codes",
		MaxLength = 24,
		Transform = string.upper,
		LayoutOrder = 1,
		Parent = panel.body,
		OnSubmit = function(text: string)
			redeem(text)
		end,
	})
	Parts.text(panel.body, 2, loc:t("codes.hint"), { size = "caption", color = "inkSoft", align = "Center" })
	local _, button = Kit.Button.new({
		Text = loc:t("codes.redeem"),
		Variant = "Success",
		Width = 240,
		Parent = panel.footer,
		OnActivated = function()
			redeem(input.getText())
		end,
	})

	local busy = false
	function redeem(text: string)
		if busy or text == "" then
			return
		end
		busy = true
		input.setLoading(true)
		button.setLoading(true)
		Parts.spawn(function()
			local result = remotes.Redeem:invokeAsync(text)
			busy = false
			input.setLoading(false)
			button.setLoading(false)
			local variant, message = Models.codeResult(loc, result, env.catalog)
			input.setVariant(variant :: any, message)
			if variant == "Success" then
				Parts.toast(env, message, "Success", nil, "icon_codes")
			end
		end)
	end

	return {
		root = root,
		defaultFocus = inputRoot,
		onShow = function()
			input.focus()
		end,
	}
end

return CodesScreen
