--!strict
--[[
	Minimal Roblox Open Cloud HTTP client for lune tools (asset upload, DataStore backups,
	Luau Execution). Adds the API key, retries 429 (honouring Retry-After) and 5xx with
	exponential backoff, and decodes JSON bodies.

	  local OpenCloud = require("./lib/opencloud")  -- from a tools/ script
	  local client = OpenCloud.new({ apiKey = process.env.ROBLOX_API_KEY })
	  local res = client:request("GET", "https://apis.roblox.com/...", { query = { limit = "100" } })
	  if res.ok then print(res.json) end

	Never log or write the API key. Keys come from the environment only.
]]

local net = require("@lune/net")
local serde = require("@lune/serde")
local task = require("@lune/task")

export type RequestOptions = {
	headers: { [string]: string }?,
	body: (string | buffer)?,
	query: { [string]: string }?,
	-- Encodes `json` as the body and sets Content-Type.
	json: any?,
}

export type Response = {
	ok: boolean,
	status: number,
	body: string,
	json: any?,
	headers: { [string]: string },
	attempts: number,
}

export type Client = {
	request: (self: Client, method: string, url: string, options: RequestOptions?) -> Response,
	multipart: (self: Client, url: string, parts: { Part }) -> Response,
}

export type Part = { name: string, filename: string?, contentType: string?, content: string }

export type Options = {
	apiKey: string,
	maxAttempts: number?,
	baseDelay: number?,
	-- Injected for tests: replaces net.request and task.wait.
	send: ((params: any) -> any)?,
	sleep: ((seconds: number) -> ())?,
	log: ((line: string) -> ())?,
}

local OpenCloud = {}

-- Overridable for tests against a local mock server.
OpenCloud.BASE = (require("@lune/process").env.ROBLOX_OPEN_CLOUD_BASE or "https://apis.roblox.com") :: string

local function shouldRetry(status: number): boolean
	return status == 429 or status >= 500
end

local function retryAfter(headers: { [string]: string }): number?
	for key, value in headers do
		if string.lower(key) == "retry-after" then
			return tonumber(value)
		end
	end
	return nil
end

function OpenCloud.new(options: Options): Client
	assert(type(options.apiKey) == "string" and options.apiKey ~= "", "OpenCloud.new: apiKey is required")
	local maxAttempts = options.maxAttempts or 5
	local baseDelay = options.baseDelay or 1
	local send: (params: any) -> any = if options.send then options.send else net.request :: any
	local sleep = options.sleep or function(seconds: number)
		task.wait(seconds)
	end
	local log = options.log or function(_line: string) end

	local client = {} :: Client

	function client.request(_self: Client, method: string, url: string, requestOptions: RequestOptions?): Response
		local opts: RequestOptions = requestOptions or {}
		local headers: { [string]: string } = { ["x-api-key"] = options.apiKey }
		local extraHeaders: { [string]: string } = opts.headers or {}
		for key, value in extraHeaders do
			headers[key] = value
		end
		local body = opts.body
		if opts.json ~= nil then
			body = serde.encode("json", opts.json, false)
			headers["Content-Type"] = "application/json"
		end

		local attempt = 0
		while true do
			attempt += 1
			local ok, raw = pcall(send, {
				url = url,
				method = method,
				headers = headers,
				body = body,
				query = opts.query,
			})
			local status = if ok then raw.statusCode else 0
			if ok and not shouldRetry(status) then
				local decoded: any = nil
				if raw.body ~= "" then
					local decodedOk, value = pcall(function()
						return serde.decode("json", raw.body)
					end)
					if decodedOk then
						decoded = value
					end
				end
				return {
					ok = status >= 200 and status < 300,
					status = status,
					body = tostring(raw.body),
					json = decoded,
					headers = raw.headers or {},
					attempts = attempt,
				}
			end
			if attempt >= maxAttempts then
				return {
					ok = false,
					status = status,
					body = if ok then tostring(raw.body) else tostring(raw),
					json = nil,
					headers = if ok then raw.headers or {} else {},
					attempts = attempt,
				}
			end
			local delay = baseDelay * 2 ^ (attempt - 1)
			if ok then
				delay = retryAfter(raw.headers or {}) or delay
			end
			log(
				string.format(
					"  retry %d/%d in %.1fs (%s %s -> %s)",
					attempt,
					maxAttempts - 1,
					delay,
					method,
					url,
					if ok then tostring(status) else "network error"
				)
			)
			sleep(delay)
		end
	end

	function client.multipart(self: Client, url: string, parts: { Part }): Response
		local boundary = "----rblxshared" .. string.format("%08x", math.random(0, 0x7FFFFFFF))
		local chunks = {}
		for _, part in parts do
			local disposition = string.format('Content-Disposition: form-data; name="%s"', part.name)
			if part.filename then
				disposition ..= string.format('; filename="%s"', part.filename)
			end
			table.insert(chunks, "--" .. boundary .. "\r\n" .. disposition .. "\r\n")
			if part.contentType then
				table.insert(chunks, "Content-Type: " .. part.contentType .. "\r\n")
			end
			table.insert(chunks, "\r\n" .. part.content .. "\r\n")
		end
		table.insert(chunks, "--" .. boundary .. "--\r\n")
		return self:request("POST", url, {
			headers = { ["Content-Type"] = "multipart/form-data; boundary=" .. boundary },
			body = table.concat(chunks),
		})
	end

	return client
end

return OpenCloud
