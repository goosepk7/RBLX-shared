--!strict
--[[
	Collects sim outputs: time series (rows), scalar metrics, and counters, then renders them
	as CSV (one file per series) and JSON (everything).

	  local rec = Recorder.new()
	  rec:row("income", { minute = 5, source = "challenge", amount = 12 })
	  rec:add("events.joined", 1)
	  rec:set("firstWin.p50", 41.2)
	  print(rec:csv("income"))

	Column order is first-seen order, so the CSV header matches how the sim wrote rows.
]]

local Json = require("./Json")

export type Cell = string | number | boolean
export type Row = { [string]: Cell }

export type Recorder = {
	row: (self: Recorder, series: string, row: Row) -> (),
	set: (self: Recorder, name: string, value: any) -> (),
	add: (self: Recorder, name: string, amount: number?) -> number,
	get: (self: Recorder, name: string) -> any,
	rows: (self: Recorder, series: string) -> { Row },
	seriesNames: (self: Recorder) -> { string },
	metrics: (self: Recorder) -> { [string]: any },
	csv: (self: Recorder, series: string) -> string,
	toTable: (self: Recorder) -> { metrics: { [string]: any }, series: { [string]: { Row } } },
	json: (self: Recorder, pretty: boolean?) -> string,
}

local Recorder = {}

local function csvCell(value: Cell?): string
	if value == nil then
		return ""
	end
	local text: string
	if type(value) == "number" then
		if value == math.floor(value) and math.abs(value) < 1e15 then
			text = string.format("%d", value)
		else
			text = tostring(value)
		end
	else
		text = tostring(value)
	end
	if string.find(text, '[,"\n\r]') then
		text = '"' .. string.gsub(text, '"', '""') .. '"'
	end
	return text
end

function Recorder.new(): Recorder
	local series: { [string]: { rows: { Row }, columns: { string }, known: { [string]: boolean } } } = {}
	local order: { string } = {}
	local metricValues: { [string]: any } = {}

	local self = {} :: Recorder

	function self.row(_self: Recorder, name: string, row: Row)
		local s = series[name]
		if not s then
			s = { rows = {}, columns = {}, known = {} }
			series[name] = s
			table.insert(order, name)
		end
		-- Record new columns in a stable order: keys sorted within the row that introduced them.
		local newKeys: { string } = {}
		for key in row do
			if not s.known[key] then
				table.insert(newKeys, key)
			end
		end
		table.sort(newKeys)
		for _, key in newKeys do
			s.known[key] = true
			table.insert(s.columns, key)
		end
		table.insert(s.rows, table.clone(row))
	end

	function self.set(_self: Recorder, name: string, value: any)
		metricValues[name] = value
	end

	function self.add(_self: Recorder, name: string, amount: number?): number
		local value = (metricValues[name] or 0) + (amount or 1)
		metricValues[name] = value
		return value
	end

	function self.get(_self: Recorder, name: string): any
		return metricValues[name]
	end

	function self.rows(_self: Recorder, name: string): { Row }
		local s = series[name]
		return if s then s.rows else {}
	end

	function self.seriesNames(_self: Recorder): { string }
		return table.clone(order)
	end

	function self.metrics(_self: Recorder): { [string]: any }
		return table.clone(metricValues)
	end

	function self.csv(_self: Recorder, name: string): string
		local s = series[name]
		if not s then
			return ""
		end
		local lines = { table.concat(s.columns, ",") }
		for _, row in s.rows do
			local cells = table.create(#s.columns, "")
			for i, column in s.columns do
				cells[i] = csvCell(row[column])
			end
			table.insert(lines, table.concat(cells, ","))
		end
		return table.concat(lines, "\n") .. "\n"
	end

	function self.toTable(_self: Recorder)
		local out: { [string]: { Row } } = {}
		for name, s in series do
			out[name] = s.rows
		end
		return { metrics = Json.object(table.clone(metricValues)), series = Json.object(out) }
	end

	function self.json(r: Recorder, pretty: boolean?): string
		return Json.encode(r:toTable(), pretty)
	end

	return self
end

return Recorder
