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
	T.it("uploads pending assets, retries a 429, polls operations, resolves Decal ids, writes ids back", function()
		if fs.isDir(TMP) then
			fs.removeDir(TMP)
		end
		fs.writeDir(TMP .. "/assets")
		fs.writeDir(TMP .. "/src/Assets")
		fs.writeFile(TMP .. "/assets/a.png", "PNG-A")
		fs.writeFile(TMP .. "/assets/b.ogg", "OGG-B")
		fs.writeFile(TMP .. "/assets/c.png", "PNG-C")
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
						name = "icon_c",
						kind = "image",
						path = "assets/c.png",
						status = "pending",
						sha256 = serde.hash("sha256", "PNG-C"),
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
				if string.find(request.body, 'filename="c.png"', 1, true) then
					return { status = 200, body = '{"path":"operations/op-c","done":true,"response":{"assetId":"333"}}' }
				end
				if string.find(request.body, '"assetType":"Decal"', 1, true) then
					return { status = 200, body = '{"path":"operations/op-image","done":false}' }
				end
				return { status = 200, body = '{"path":"operations/op-audio","done":true,"response":{"assetId":"222"}}' }
			elseif request.method == "GET" and request.path == "/assets/v1/operations/op-image" then
				return { status = 200, body = '{"path":"operations/op-image","done":true,"response":{"assetId":"111"}}' }
			elseif request.method == "GET" and request.path == "/asset-delivery-api/v1/assetId/111" then
				return { status = 200, body = string.format('{"location":"http://127.0.0.1:%d/cdn/111"}', port) }
			elseif request.method == "GET" and request.path == "/cdn/111" then
				-- A Decal model: the Texture points at the Image (555); 111 is the Decal itself.
				return {
					status = 200,
					body = '<roblox><Item class="Decal"><Properties><Content name="Texture">'
						.. "<url>http://www.roblox.com/asset/?id=555</url></Content></Properties></Item></roblox>",
				}
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

		if not string.find(result.stdout, "1 unresolved", 1, true) then
			print(result.stdout, result.stderr)
		end
		-- icon_c's Decal can't be resolved (asset delivery 404s), so the run reports it and fails.
		expect(result.ok).toBe(false)
		expect(result.stdout).toContain("anim_walk")
		expect(result.stdout).toContain("FAIL  2 uploaded, 1 unresolved, 0 failed")
		expect(result.stdout).toContain("tools/resolve_decals")

		local manifest = serde.decode("json", fs.readFile(TMP .. "/assets/manifest.json"))
		local byName: { [string]: any } = {}
		for _, entry in manifest.assets do
			byName[entry.name] = entry
		end
		expect(byName.icon_a.status).toBe("uploaded")
		expect(byName.icon_a.assetId).toBe(555)
		expect(byName.icon_a.decalId).toBe(111)
		expect(byName.icon_c.status).toBe("unresolved")
		expect(byName.icon_c.assetId).toBeNil()
		expect(byName.icon_c.decalId).toBe(333)
		expect(byName.sfx_b.assetId).toBe(222)
		expect(byName.anim_walk.status).toBe("pending")

		local ids = fs.readFile(TMP .. "/src/Assets/AssetIds.luau")
		expect(ids).toContain('icon_a = { kind = "image", status = "uploaded", assetId = 555 }')
		expect(ids).toContain('icon_c = { kind = "image", status = "pending", assetId = nil }')

		for _, r in requests do
			-- The signed CDN download must never see the API key.
			if string.sub(r.path, 1, 5) == "/cdn/" then
				expect(r.key).toBeNil()
			else
				expect(r.key).toBe("test-key")
			end
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
		expect(again.stdout).toContain("icon_c is unresolved (decal 333)")

		-- Studio fallback: print the script, then apply its output.
		local resolveTool = process.cwd .. "/tools/resolve_decals"
		local script = process.exec("lune", { "run", resolveTool, "--studio-script" }, { cwd = TMP })
		expect(script.stdout).toContain("icon_c = 333,")
		expect(script.stdout).toContain("InsertService")
		fs.writeFile(TMP .. "/ids.json", '{"icon_c": 777}')
		local applied = process.exec("lune", { "run", resolveTool, "--apply", "ids.json" }, { cwd = TMP })
		if not applied.ok then
			print(applied.stdout, applied.stderr)
		end
		expect(applied.ok).toBe(true)
		expect(applied.stdout).toContain("PASS  1 resolved, 0 still unresolved")
		local after = serde.decode("json", fs.readFile(TMP .. "/assets/manifest.json"))
		for _, entry in after.assets do
			if entry.name == "icon_c" then
				expect(entry.status).toBe("uploaded")
				expect(entry.assetId).toBe(777)
				expect(entry.decalId).toBe(333)
			end
		end
		expect(fs.readFile(TMP .. "/src/Assets/AssetIds.luau")).toContain(
			'icon_c = { kind = "image", status = "uploaded", assetId = 777 }'
		)
	end)
end)
