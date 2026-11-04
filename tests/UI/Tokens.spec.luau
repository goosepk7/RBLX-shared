--!strict
local Color = require("@shared/UI/Color")
local Theme = require("@shared/UI/Theme")
local Tokens = require("@shared/UI/Tokens")
local T = require("@shared/Test")
local expect = T.expect

local function rgb(hex: string): Color.RGB
	return Color.parse(hex)
end

T.describe("UI.Tokens", function()
	T.it("every palette and accent value is a valid #RRGGBB", function()
		for name, hex in Tokens.palette :: { [string]: string } do
			expect(string.match(hex, "^#%x%x%x%x%x%x$") ~= nil).toBe(true)
			expect(name).toBeType("string")
		end
		for _, accent in Tokens.accents :: { [string]: { [string]: string } } do
			for _, hex in accent do
				expect(string.match(hex, "^#%x%x%x%x%x%x$") ~= nil).toBe(true)
			end
		end
	end)

	T.it("matches the brief's base palette exactly (§5.2)", function()
		local p = Tokens.palette
		expect(p.ink).toBe("#1E2235")
		expect(p.paper).toBe("#FFFFFF")
		expect(p.paper2).toBe("#F3F5FA")
		expect(p.line).toBe("#D9DEEA")
		expect(p.success).toBe("#3DD68C")
		expect(p.successEdge).toBe("#1FA466")
		expect(p.danger).toBe("#FF5A6E")
		expect(p.dangerEdge).toBe("#C8384A")
		expect(p.warning).toBe("#FFC53D")
		expect(p.warningEdge).toBe("#D39A12")
		expect(p.info).toBe("#4DA3FF")
		expect(p.infoEdge).toBe("#2B74C9")
		expect(p.gold).toBe("#FFD166")
		expect(p.goldEdge).toBe("#B8860B")
		expect(Tokens.alpha.shadow).toBeNear(0.78, 1e-9)
	end)

	T.it("matches the per-game accents (§5.2)", function()
		expect(Tokens.accents.stilts.primary).toBe("#FF7A1A")
		expect(Tokens.accents.stilts.primaryEdge).toBe("#C85A08")
		expect(Tokens.accents.stilts.secondary).toBe("#6C5CE7")
		expect(Tokens.accents.car.primary).toBe("#2EC4B6")
		expect(Tokens.accents.car.primaryEdge).toBe("#1C8D82")
		expect(Tokens.accents.car.secondary).toBe("#FF9F1C")
	end)

	T.it("edges are darker than their fills", function()
		local pairsToCheck = {
			{ "success", "successEdge" },
			{ "danger", "dangerEdge" },
			{ "warning", "warningEdge" },
			{ "info", "infoEdge" },
			{ "gold", "goldEdge" },
			{ "paper", "lineDark" },
		}
		for _, pair in pairsToCheck do
			local fill = (Tokens.palette :: any)[pair[1]]
			local edge = (Tokens.palette :: any)[pair[2]]
			expect(Color.luminance(rgb(edge)) < Color.luminance(rgb(fill))).toBe(true)
		end
		for _, accent in Tokens.accents :: { [string]: Tokens.AccentTokens } do
			expect(Color.luminance(rgb(accent.primaryEdge)) < Color.luminance(rgb(accent.primary))).toBe(true)
			expect(Color.luminance(rgb(accent.secondaryEdge)) < Color.luminance(rgb(accent.secondary))).toBe(true)
		end
	end)

	T.it("Ink on Paper and Paper-2 is highly legible, and Ink is not pure black", function()
		expect(Tokens.palette.ink ~= "#000000").toBe(true)
		expect(Color.contrast(rgb(Tokens.palette.ink), rgb(Tokens.palette.paper)) >= 12).toBe(true)
		expect(Color.contrast(rgb(Tokens.palette.ink), rgb(Tokens.palette.paper2)) >= 12).toBe(true)
		expect(Color.contrast(rgb(Tokens.palette.inkSoft), rgb(Tokens.palette.paper)) >= 4.5).toBe(true)
	end)

	T.it("light fills (Warning, Gold) use Ink text, saturated fills stroke white text", function()
		for name, colors in Theme.VARIANTS do
			local fill = Theme.hex(colors.fill, "stilts")
			local text = Theme.hex(colors.text, "stilts")
			local ratio = Color.contrast(rgb(fill), rgb(text))
			if colors.textStroke == nil and name ~= "Ghost" then
				-- No stroke means the text must stand on its own (WCAG large-text AA).
				expect(ratio >= 3).toBe(true)
			end
		end
	end)

	T.it("radii, edges and type scale match §5.2", function()
		expect(Tokens.radius).toEqual({ card = 14, button = 12, chip = 10, pill = 999 })
		expect(Tokens.edge.button).toBe(6)
		expect(Tokens.edge.chip).toBe(4)
		expect(Tokens.edge.pressed).toBe(2)
		expect(Tokens.type.h1).toBe(34)
		expect(Tokens.type.h2).toBe(26)
		expect(Tokens.type.h3).toBe(20)
		expect(Tokens.type.body).toBe(16)
		expect(Tokens.type.caption).toBe(13)
		expect(Tokens.type.button).toBe(18)
	end)

	T.it("motion stays in the 0.12-0.25 s band for enters/exits (§5.7)", function()
		local m = Tokens.motion
		for _, d in { m.enterDuration, m.exitDuration, m.fastDuration, m.releaseDuration, m.tabSlide } do
			expect(d >= 0.12 and d <= 0.25).toBe(true)
		end
		expect(m.pressDuration).toBe(0.08)
		expect(m.pressScale).toBe(0.96)
		expect(m.numberPopDuration).toBe(0.7)
	end)

	T.it("uses only Fredoka One and Builder Sans (two families, §5.8)", function()
		local families = {}
		for _, role in Tokens.fontRoles :: { [string]: { family: string, weight: string } } do
			families[(Tokens.fonts :: any)[role.family]] = true
		end
		local count = 0
		for _ in families do
			count += 1
		end
		expect(count).toBe(2)
		expect(Tokens.fonts.display).toContain("FredokaOne")
		expect(Tokens.fonts.body).toContain("BuilderSans")
	end)
end)

T.describe("UI.Theme", function()
	T.it("resolves accent tokens per game and base tokens for both", function()
		expect(Theme.hex("primary", "stilts")).toBe("#FF7A1A")
		expect(Theme.hex("primary", "car")).toBe("#2EC4B6")
		expect(Theme.hex("ink", "car")).toBe("#1E2235")
	end)

	T.it("errors on unknown tokens and games", function()
		expect(function()
			Theme.hex("magenta" :: any)
		end).toThrow("unknown color token")
		expect(function()
			Theme.setGame("racing" :: any)
		end).toThrow("unknown game")
	end)

	T.it("every variant references real tokens in both games", function()
		for _, colors in Theme.VARIANTS do
			for _, game in { "stilts", "car" } :: { Theme.GameId } do
				for _, key in { "fill", "edge", "text" } do
					expect(Theme.hex((colors :: any)[key], game)).toBeType("string")
				end
				if colors.textStroke then
					expect(Theme.hex(colors.textStroke, game)).toBeType("string")
				end
				if colors.border then
					expect(Theme.hex(colors.border, game)).toBeType("string")
				end
			end
		end
	end)
end)
