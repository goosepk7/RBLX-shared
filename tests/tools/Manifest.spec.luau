--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local T = require("@shared/Test")
local Manifest = require("@tools/lib/manifest")
local expect = T.expect

local TMP = "build/test-tmp/manifest"

local function write(path: string, content: string)
	fs.writeFile(TMP .. "/" .. path, content)
end

local function problemsFor(manifest: Manifest.Manifest): { string }
	local out = {}
	for _, p in Manifest.validate(manifest, true) do
		table.insert(out, p.name .. ": " .. p.message)
	end
	return out
end

T.describe("tools/lib/manifest", function()
	T.beforeEach(function()
		if fs.isDir(TMP) then
			fs.removeDir(TMP)
		end
		fs.writeDir(TMP)
		write("a.png", "PNGDATA")
	end)

	T.it("accepts a valid pending entry with the right hash", function()
		local m: Manifest.Manifest = {
			version = 1,
			assets = {
				{
					name = "icon_a",
					kind = "image",
					path = TMP .. "/a.png",
					status = "pending",
					sha256 = serde.hash("sha256", "PNGDATA"),
				},
			},
		}
		expect(problemsFor(m)).toEqual({})
	end)

	T.it("flags bad names, kinds, statuses, ids, missing files and stale hashes", function()
		local m: Manifest.Manifest = {
			version = 1,
			assets = {
				{ name = "Bad-Name", kind = "image", path = TMP .. "/a.png", status = "pending", sha256 = "x" },
				{ name = "k", kind = "texture", path = TMP .. "/a.png", status = "pending" },
				{ name = "s", kind = "image", path = TMP .. "/a.png", status = "done" },
				{ name = "u", kind = "image", path = TMP .. "/a.png", status = "uploaded", assetId = nil },
				{ name = "m", kind = "audio", path = TMP .. "/missing.ogg", status = "pending" },
				{ name = "c", kind = "audio", source = "creator-store", status = "pending" },
				{ name = "k", kind = "image", path = TMP .. "/a.png", status = "pending", sha256 = "" },
			},
		}
		local text = table.concat(problemsFor(m), "\n")
		expect(text).toContain("Bad-Name: name must be snake_case")
		expect(text).toContain("Bad-Name: sha256 is stale")
		expect(text).toContain("k: unknown kind texture")
		expect(text).toContain("s: status must be pending or uploaded")
		expect(text).toContain("u: uploaded entries need a positive integer assetId")
		expect(text).toContain("m: file not found")
		expect(text).toContain("c: creator-store entries reference an existing id")
		expect(text).toContain("k: duplicate name")
		expect(text).toContain("k: sha256 missing")
	end)

	T.it("detects files that changed after upload", function()
		local m: Manifest.Manifest = {
			version = 1,
			assets = {
				{
					name = "icon_a",
					kind = "image",
					path = TMP .. "/a.png",
					status = "uploaded",
					assetId = 99,
					sha256 = serde.hash("sha256", "OLD"),
				},
			},
		}
		expect(problemsFor(m)[1]).toContain("file changed since upload")
	end)

	T.it("encodes deterministically and round-trips through load", function()
		local m: Manifest.Manifest = {
			version = 1,
			assets = {
				{ name = "b", kind = "audio", path = "x.ogg", status = "pending", sha256 = "h" },
				{
					name = "a",
					kind = "image",
					path = "y.png",
					status = "uploaded",
					assetId = 5,
					sha256 = "h2",
					meta = { bpm = 100 },
				},
			},
		}
		local text = Manifest.encode(m)
		expect(text).toBe(table.concat({
			"{",
			'  "assets": [',
			"    {",
			'      "name": "a",',
			'      "kind": "image",',
			'      "path": "y.png",',
			'      "status": "uploaded",',
			'      "assetId": 5,',
			'      "sha256": "h2",',
			'      "meta": {"bpm":100}',
			"    },",
			"    {",
			'      "name": "b",',
			'      "kind": "audio",',
			'      "path": "x.ogg",',
			'      "status": "pending",',
			'      "assetId": null,',
			'      "sha256": "h"',
			"    }",
			"  ],",
			'  "version": 1',
			"}",
			"",
		}, "\n"))
		write("m.json", text)
		local loaded = Manifest.load(TMP .. "/m.json")
		expect(#loaded.assets).toBe(2)
		expect(loaded.assets[2].assetId).toBeNil()
		expect(Manifest.encode(loaded)).toBe(text)
	end)

	T.it("renders AssetIds.luau sorted, with nil for pending ids", function()
		local m: Manifest.Manifest = {
			version = 1,
			assets = {
				{ name = "z", kind = "audio", status = "pending" },
				{ name = "a", kind = "image", status = "uploaded", assetId = 42 },
			},
		}
		local out = Manifest.renderIds(m, "assets/manifest.json")
		expect(out).toContain(
			'\ta = { kind = "image", status = "uploaded", assetId = 42 },\n\tz = { kind = "audio", status = "pending", assetId = nil },'
		)
		expect(out).toContain("return ids")
	end)
end)
