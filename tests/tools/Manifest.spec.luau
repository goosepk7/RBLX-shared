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
		expect(text).toContain("s: status must be pending, unresolved or uploaded")
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

	T.it("enforces decal rules: assetId is the Image id, unresolved needs a decalId", function()
		local hash = serde.hash("sha256", "PNGDATA")
		local png = TMP .. "/a.png"
		local m: Manifest.Manifest = {
			version = 1,
			assets = {
				{
					name = "ok",
					kind = "image",
					path = png,
					status = "uploaded",
					assetId = 7,
					decalId = 6,
					sha256 = hash,
				},
				{
					name = "same",
					kind = "image",
					path = png,
					status = "uploaded",
					assetId = 6,
					decalId = 6,
					sha256 = hash,
				},
				{ name = "wait", kind = "image", path = png, status = "unresolved", decalId = 6, sha256 = hash },
				{ name = "nodecal", kind = "image", path = png, status = "unresolved", sha256 = hash },
				{
					name = "withid",
					kind = "image",
					path = png,
					status = "unresolved",
					assetId = 9,
					decalId = 6,
					sha256 = hash,
				},
				{ name = "snd", kind = "audio", path = png, status = "pending", decalId = 6, sha256 = hash },
			},
		}
		local text = table.concat(problemsFor(m), "\n")
		expect(text).never.toContain("ok:")
		expect(text).never.toContain("wait:")
		expect(text).toContain("same: assetId equals decalId")
		expect(text).toContain("nodecal: unresolved entries must be images with a decalId")
		expect(text).toContain("withid: unresolved entries must have assetId null")
		expect(text).toContain("snd: decalId is only valid on image entries")
	end)

	T.it("renders unresolved entries as pending with no id", function()
		local m: Manifest.Manifest = {
			version = 1,
			assets = { { name = "i", kind = "image", status = "unresolved", decalId = 6 } },
		}
		expect(Manifest.renderIds(m, "m.json")).toContain(
			'\ti = { kind = "image", status = "pending", assetId = nil },'
		)
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
