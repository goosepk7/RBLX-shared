--!strict
--[[
	RBLXShared.UI: theme tokens, component kit, screen manager, safe area,
	feedback hooks and the /uigallery. See docs/UI.md.

	Requiring this module touches no Roblox services, so lune tests can
	require it; everything that builds Instances does so when called.
]]

return {
	Color = require("@self/Color"),
	Create = require("@self/Create"),
	Format = require("@self/Format"),
	Gallery = require("@self/Gallery"),
	Gestures = require("@self/Gestures"),
	Hooks = require("@self/Hooks"),
	Kit = require("@self/Kit"),
	Layout = require("@self/Layout"),
	Motion = require("@self/Motion"),
	SafeArea = require("@self/SafeArea"),
	ScreenManager = require("@self/ScreenManager"),
	Theme = require("@self/Theme"),
	Tokens = require("@self/Tokens"),
}
