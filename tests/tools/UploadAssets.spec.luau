--!strict
--[[
	End-to-end: runs tools/upload_assets against a local mock of the Open Cloud Assets API
	and checks the manifest and AssetIds module it writes.
]]

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")

local T = require("@shared/Test")
local expect = T.expect

local TMP = "build/test-tmp/upload"

T.describe("tools/upload_assets (mock Open Cloud)", function()
	T.it("uploads pending assets, retries a 429, polls operations, writes ids back", function()
		if fs.isDir(TMP) then
			fs.removeDir(TMP)
		end
		fs.writeDir(TMP .. "/assets")
		fs.writeDir(TMP .. "/src/Assets")
		fs.writeFile(TMP .. "/assets/a.png", "PNG-A")
		fs.writeFile(TMP .. "/assets/b.ogg", "OGG-B")
		fs.writeFile(TMP .. "/assets/walk.rbxm", "RBXM")
		fs.writeFile(
			TMP .. "/assets/manifest.json",
			serde.encode("json", {
				version = 1,
				assets = {
					{
						name = "icon_a",
						kind = "image",
						path = "assets/a.png",
						status = "pending",
						sha256 = serde.hash("sha256", "PNG-A"),
					},
					{
						name = "sfx_b",
						kind = "audio",
						path = "assets/b.ogg",
						status = "pending",
						sha256 = serde.hash("sha256", "OGG-B"),
					},
					{
						name = "anim_walk",
						kind = "animation",
						path = "assets/walk.rbxm",
						status = "pending",
						sha256 = serde.hash("sha256", "RBXM"),
					},
				},
			}, true)
		)

		local requests: { { method: string, path: string, key: string?, body: string } } = {}
		local posts = 0
		local port = 47000 + (os.time() % 1000)
		local server = net.serve(port, function(request)
			table.insert(requests, {
				method = request.method :: string,
				path = request.path,
				key = request.headers["x-api-key"] :: string?,
				body = request.body,
			})
			if request.method == "POST" and request.path == "/assets/v1/assets" then
				posts += 1
				if posts == 1 then
					return { status = 429, headers = { ["Retry-After"] = "0" }, body = "" }
				end
				if string.find(request.body, '"assetType":"Decal"', 1, true) then
					return { status = 200, body = '{"path":"operations/op-image","done":false}' }
				end
				return { status = 200, body = '{"path":"operations/op-audio","done":true,"response":{"assetId":"222"}}' }
			elseif request.method == "GET" and request.path == "/assets/v1/operations/op-image" then
				return { status = 200, body = '{"path":"operations/op-image","done":true,"response":{"assetId":"111"}}' }
			end
			return { status = 404, body = "not found" }
		end)

		local result = process.exec("lune", { "run", process.cwd .. "/tools/upload_assets", "--all" }, {
			cwd = TMP,
			env = {
				ROBLOX_API_KEY = "test-key",
				ROBLOX_CREATOR_USER_ID = "42",
				ROBLOX_OPEN_CLOUD_BASE = string.format("http://127.0.0.1:%d", port),
				UPLOAD_POLL_INTERVAL = "0",
			},
		})
		server:stop()

		if not result.ok then
			print(result.stdout, result.stderr)
		end
		expect(result.ok).toBe(true)
		expect(result.stdout).toContain("anim_walk")
		expect(result.stdout).toContain("PASS  2 uploaded, 0 failed")

		local manifest = serde.decode("json", fs.readFile(TMP .. "/assets/manifest.json"))
		local byName: { [string]: any } = {}
		for _, entry in manifest.assets do
			byName[entry.name] = entry
		end
		expect(byName.icon_a.status).toBe("uploaded")
		expect(byName.icon_a.assetId).toBe(111)
		expect(byName.sfx_b.assetId).toBe(222)
		expect(byName.anim_walk.status).toBe("pending")

		local ids = fs.readFile(TMP .. "/src/Assets/AssetIds.luau")
		expect(ids).toContain('icon_a = { kind = "image", status = "uploaded", assetId = 111 }')

		for _, r in requests do
			expect(r.key).toBe("test-key")
		end
		local first = requests[2]
		expect(first.body).toContain('"creator":{"userId":"42"}')
		expect(first.body).toContain('filename="a.png"')

		-- Second run: nothing left to upload.
		local again = process.exec(
			"lune",
			{ "run", process.cwd .. "/tools/upload_assets", "--all", "--dry-run" },
			{ cwd = TMP }
		)
		expect(again.stdout).toContain("0 asset(s) to upload")
	end)
end)
