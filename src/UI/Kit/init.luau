--!strict
--[[
	The component kit (§5.3). Every component module exports `new` (or
	`show`/`spawn`/`lane` for transient ones) and a `Variants` list; the
	gallery and tests/UI/stories.spec.luau use `Variants` to prove every
	variant has a story.
]]

return {
	Banner = require("@self/Banner"),
	Button = require("@self/Button"),
	Card = require("@self/Card"),
	Chip = require("@self/Chip"),
	Confetti = require("@self/Confetti"),
	Confirm = require("@self/Confirm"),
	CurrencyPill = require("@self/CurrencyPill"),
	Drawer = require("@self/Drawer"),
	Grid = require("@self/Grid"),
	IconButton = require("@self/IconButton"),
	ListRow = require("@self/ListRow"),
	Modal = require("@self/Modal"),
	NumberPop = require("@self/NumberPop"),
	Panel = require("@self/Panel"),
	ProgressBar = require("@self/ProgressBar"),
	Stat = require("@self/Stat"),
	Tabs = require("@self/Tabs"),
	Toast = require("@self/Toast"),
	Tooltip = require("@self/Tooltip"),
}
