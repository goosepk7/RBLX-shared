--!strict
local T = require("@shared/Test")
local OpenCloud = require("@tools/lib/opencloud")
local expect = T.expect

type Reply = { statusCode: number, body: string, headers: { [string]: string }? }

local function fakeClient(replies: { Reply | string })
	local sent: { any } = {}
	local slept: { number } = {}
	local client = OpenCloud.new({
		apiKey = "test-key",
		maxAttempts = 4,
		baseDelay = 1,
		send = function(params)
			table.insert(sent, params)
			local reply = table.remove(replies, 1)
			if type(reply) == "string" then
				error(reply)
			end
			local r = reply :: Reply
			return {
				ok = r.statusCode < 400,
				statusCode = r.statusCode,
				statusMessage = "",
				headers = r.headers or {},
				body = r.body,
			}
		end,
		sleep = function(seconds)
			table.insert(slept, seconds)
		end,
	})
	return client, sent, slept
end

T.describe("tools/lib/opencloud", function()
	T.it("sends the api key and decodes JSON", function()
		local client, sent = fakeClient({ { statusCode = 200, body = '{"a":1}' } })
		local res = client:request("GET", "https://x/y", { query = { limit = "10" } })
		expect(res.ok).toBe(true)
		expect(res.json).toEqual({ a = 1 })
		expect(sent[1].headers["x-api-key"]).toBe("test-key")
		expect(sent[1].query).toEqual({ limit = "10" })
	end)

	T.it("retries 429 honouring Retry-After, and 5xx with exponential backoff", function()
		local client, sent, slept = fakeClient({
			{ statusCode = 429, body = "", headers = { ["Retry-After"] = "7" } },
			{ statusCode = 503, body = "" },
			"connection reset",
			{ statusCode = 200, body = "{}" },
		})
		local res = client:request("POST", "https://x/y", { json = { k = "v" }, retry = "all" })
		expect(res.ok).toBe(true)
		expect(res.attempts).toBe(4)
		expect(slept).toEqual({ 7, 2, 4 })
		expect(sent[1].body).toBe('{"k":"v"}')
		expect(sent[1].headers["Content-Type"]).toBe("application/json")
	end)

	T.it("does not retry 4xx and gives up after maxAttempts", function()
		local client = fakeClient({ { statusCode = 403, body = '{"message":"denied"}' } })
		local res = client:request("GET", "https://x/y")
		expect(res.ok).toBe(false)
		expect(res.status).toBe(403)
		expect(res.attempts).toBe(1)
		local failing = fakeClient({
			{ statusCode = 500, body = "" },
			{ statusCode = 500, body = "" },
			{ statusCode = 500, body = "" },
			{ statusCode = 500, body = "e" },
		})
		local final = failing:request("GET", "https://x/y")
		expect(final.ok).toBe(false)
		expect(final.attempts).toBe(4)
	end)

	T.it("POST defaults to safe retries: 429 and network errors, never 5xx", function()
		local client, sent = fakeClient({
			{ statusCode = 429, body = "", headers = { ["Retry-After"] = "0" } },
			"connection reset",
			{ statusCode = 502, body = "bad gateway" },
			{ statusCode = 200, body = "{}" },
		})
		local res = client:request("POST", "https://x/create")
		expect(res.ok).toBe(false)
		expect(res.status).toBe(502)
		expect(res.attempts).toBe(3)
		expect(#sent).toBe(3)

		local multi, multiSent = fakeClient({ { statusCode = 500, body = "" }, { statusCode = 200, body = "{}" } })
		local upload = multi:multipart("https://x/upload", { { name = "request", content = "{}" } })
		expect(upload.status).toBe(500)
		expect(#multiSent).toBe(1)
	end)

	T.it("omits the api key when auth = false", function()
		local client, sent = fakeClient({ { statusCode = 200, body = "x" } })
		client:request("GET", "https://cdn/signed", { auth = false })
		expect(sent[1].headers["x-api-key"]).toBeNil()
	end)

	T.it("builds multipart bodies", function()
		local client, sent = fakeClient({ { statusCode = 200, body = "{}" } })
		client:multipart("https://x/upload", {
			{ name = "request", contentType = "application/json", content = "{}" },
			{ name = "fileContent", filename = "a.png", contentType = "image/png", content = "BYTES" },
		})
		local contentType = sent[1].headers["Content-Type"]
		local boundary = string.match(contentType, "boundary=(.+)$")
		expect(boundary).never.toBeNil()
		local body = sent[1].body
		expect(body).toContain('name="fileContent"; filename="a.png"')
		expect(body).toContain("Content-Type: image/png\r\n\r\nBYTES\r\n")
		expect(body).toContain("--" .. tostring(boundary) .. "--\r\n")
	end)
end)
