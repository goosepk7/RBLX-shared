--!strict
--[[
	Log: scoped, non-fatal reporting for framework code.

	  Log.warn("Data", "save failed, retrying")
	  Log.error("Net", "handler for Stilts.Lunge errored:\n" .. traceback)

	In Roblox, `error` reports show red in the Output window (with the message) without stopping
	the calling thread; `warn` reports show yellow. Under lune both print to stderr-style output.

	Tests capture reports with Log.capture(), which returns the list it appends to and a
	function that restores normal output. Framework code never swallows an error silently: it
	either rethrows or reports it here.
]]

export type Level = "info" | "warn" | "error"

export type Entry = {
	level: Level,
	scope: string,
	message: string,
}

export type Sink = (entry: Entry) -> ()

local Log = {}

local sink: Sink? = nil

local function format(scope: string, message: string): string
	return "[RBLXShared." .. scope .. "] " .. message
end

local function emit(level: Level, scope: string, message: string)
	local current = sink
	if current then
		current({ level = level, scope = scope, message = message })
		return
	end
	local text = format(scope, message)
	if level == "info" then
		print(text)
	elseif level == "warn" then
		warn(text)
	else
		local taskLib = task :: any
		if taskLib ~= nil then
			-- Raise on a fresh thread: shows as a real error (red, with source) and the caller
			-- keeps running.
			taskLib.spawn(error, text, 0)
		else
			warn("ERROR " .. text)
		end
	end
end

function Log.info(scope: string, message: string)
	emit("info", scope, message)
end

function Log.warn(scope: string, message: string)
	emit("warn", scope, message)
end

function Log.error(scope: string, message: string)
	emit("error", scope, message)
end

-- Replaces the output with a custom sink (nil restores the default).
function Log.setSink(newSink: Sink?)
	sink = newSink
end

-- Test helper: records every report into the returned list until `restore` is called.
function Log.capture(): ({ Entry }, () -> ())
	local entries: { Entry } = {}
	local previous = sink
	sink = function(entry: Entry)
		table.insert(entries, entry)
	end
	return entries, function()
		sink = previous
	end
end

return Log
