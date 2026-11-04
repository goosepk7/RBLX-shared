--!strict
--[[
	TextFilter: text a player typed that other players will see goes through Roblox's text filter
	before it is stored or shown (brief §3.4). Server only.

		local filter = Shared.TextFilter.new() -- uses TextService when called
		local name = Shared.TextFilter.clean(raw, 20)
		local filtered, failure = filter:broadcast(name, player.UserId)
		if filtered == nil then
			-- failure == "unavailable": keep the old text or refuse the change
		elseif filtered ~= name then
			-- the filter replaced something with "#"
		end

	- `TextFilter.clean(text, maxChars)` first: it drops invalid UTF-8 and control characters,
	  turns every run of whitespace into one space, trims, and keeps at most `maxChars`
	  characters (codepoints). Length checks and the filter both see the cleaned text.
	- `broadcast(text, fromUserId)` asks for the strictest filtering, the one fit for text every
	  player can see (`GetNonChatStringForBroadcastAsync`): vehicle and blueprint names, plinth
	  labels. `fromUserId` is the player who typed it, or who pasted a code that carries it.
	- It fails closed. When the service errors on every try (`retries` extra tries, `retryDelay`
	  apart), it returns nil and "unavailable"; callers keep the old text or refuse the change and
	  never store the raw input.
	- Results are cached per (user, text) for `cacheSeconds`, so saving the same name twice asks
	  the service once.

	Under lune there is no TextService: tests pass `backend` (and `wait`, `now`).
]]

export type Failure = "unavailable"

-- (text, fromUserId) -> filtered text. May error; the filter retries and then fails closed.
export type Backend = (text: string, fromUserId: number) -> string

export type Options = {
	backend: Backend?, -- default: TextService broadcast filtering
	retries: number?, -- extra tries after an error (default 2)
	retryDelay: number?, -- seconds between tries (default 0.5)
	cacheSeconds: number?, -- default 300
	cacheSize: number?, -- most cached results (default 256)
	wait: ((seconds: number) -> ())?, -- default task.wait
	now: (() -> number)?, -- default os.clock
}

export type Filter = {
	broadcast: (self: Filter, text: string, fromUserId: number) -> (string?, Failure?),
}

type CacheEntry = { text: string, expires: number }

local TextFilter = {}

TextFilter.DEFAULT_RETRIES = 2
TextFilter.DEFAULT_RETRY_DELAY = 0.5
TextFilter.DEFAULT_CACHE_SECONDS = 300
TextFilter.DEFAULT_CACHE_SIZE = 256

-- Codepoints dropped besides C0/C1 controls: zero-width and direction marks, line and paragraph
-- separators, the byte-order mark. They hide text or flip its direction in a label.
local INVISIBLE: { [number]: boolean } = {
	[0x200B] = true,
	[0x200C] = true,
	[0x200D] = true,
	[0x200E] = true,
	[0x200F] = true,
	[0x2028] = true,
	[0x2029] = true,
	[0x202A] = true,
	[0x202B] = true,
	[0x202C] = true,
	[0x202D] = true,
	[0x202E] = true,
	[0x2060] = true,
	[0x2066] = true,
	[0x2067] = true,
	[0x2068] = true,
	[0x2069] = true,
	[0xFEFF] = true,
}

local function isSpace(cp: number): boolean
	return cp == 0x20
		or cp == 0x09
		or cp == 0x0A
		or cp == 0x0D
		or cp == 0x0B
		or cp == 0x0C
		or cp == 0xA0
		or cp == 0x3000
end

-- The text with every invalid UTF-8 byte removed.
local function validUtf8(text: string): string
	local out = text
	while true do
		local len, bad = utf8.len(out)
		if len ~= nil then
			return out
		end
		local at = bad :: number
		out = string.sub(out, 1, at - 1) .. string.sub(out, at + 1)
	end
end

--- Cleaned text for names and labels: valid UTF-8, no control or invisible characters,
--- single spaces, trimmed, at most `maxChars` characters.
function TextFilter.clean(text: string, maxChars: number?): string
	local limit = maxChars or math.huge
	local parts: { string } = {}
	local count = 0
	local pendingSpace = false
	for _, cp in utf8.codes(validUtf8(text)) do
		if isSpace(cp) then
			pendingSpace = count > 0
		elseif cp >= 0x20 and not (cp >= 0x7F and cp <= 0x9F) and not INVISIBLE[cp] then
			-- A space only goes in when the character after it fits too.
			local need = if pendingSpace then 2 else 1
			if count + need > limit then
				break
			end
			if pendingSpace then
				table.insert(parts, " ")
				pendingSpace = false
			end
			table.insert(parts, utf8.char(cp))
			count += need
		end
	end
	return table.concat(parts)
end

local function robloxBackend(text: string, fromUserId: number): string
	local TextService = game:GetService("TextService")
	local result = TextService:FilterStringAsync(text, fromUserId, Enum.TextFilterContext.PublicChat)
	return result:GetNonChatStringForBroadcastAsync()
end

function TextFilter.new(options: Options?): Filter
	local o: Options = options or {}
	local backend: Backend = o.backend or robloxBackend
	local retries = o.retries or TextFilter.DEFAULT_RETRIES
	local retryDelay = o.retryDelay or TextFilter.DEFAULT_RETRY_DELAY
	local cacheSeconds = o.cacheSeconds or TextFilter.DEFAULT_CACHE_SECONDS
	local cacheSize = o.cacheSize or TextFilter.DEFAULT_CACHE_SIZE
	local wait = o.wait or function(seconds: number)
		task.wait(seconds)
	end
	local now = o.now or os.clock

	local cache: { [string]: CacheEntry } = {}
	local cached = 0

	local function remember(key: string, text: string)
		local t = now()
		if cache[key] == nil then
			if cached >= cacheSize then
				for k, entry in cache do
					if entry.expires <= t then
						cache[k] = nil
						cached -= 1
					end
				end
				if cached >= cacheSize then
					table.clear(cache)
					cached = 0
				end
			end
			cached += 1
		end
		cache[key] = { text = text, expires = t + cacheSeconds }
	end

	local self = {}

	function self.broadcast(_self: Filter, text: string, fromUserId: number): (string?, Failure?)
		if text == "" then
			return "", nil
		end
		local key = tostring(fromUserId) .. "\0" .. text
		local hit = cache[key]
		if hit and hit.expires > now() then
			return hit.text, nil
		end
		for attempt = 0, retries do
			if attempt > 0 then
				wait(retryDelay)
			end
			local ok, result = pcall(backend, text, fromUserId)
			if ok and type(result) == "string" then
				remember(key, result)
				return result, nil
			end
		end
		return nil, "unavailable"
	end

	return (self :: any) :: Filter
end

return TextFilter
