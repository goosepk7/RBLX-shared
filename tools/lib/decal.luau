--!strict
--[[
	Decal -> Image id resolution.

	Open Cloud uploads images as Decal assets, but ImageLabel.Image needs the id of the Image
	the Decal wraps. The Decal's content is a tiny model whose Decal.Texture points at that
	Image, so: ask Asset Delivery for the Decal's download location, fetch it, and read the
	texture id out of it.

	  local imageId, err = Decal.resolve(client, decalId)

	NOT YET VERIFIED against live Roblox (no API key until publish). If the endpoint or the
	content format differs, entries stay "unresolved" and tools/resolve_decals has a Studio
	fallback (InsertService:LoadAsset).
]]

local OpenCloud = require("./opencloud")

local Decal = {}

-- First asset id in a Decal model body that is not the Decal itself. Matches XML
-- (<url>http://www.roblox.com/asset/?id=N</url>) and rbxassetid://N, in text or binary rbxm.
function Decal.parseImageId(body: string, decalId: number): number?
	for _, pattern in { "rbxassetid://(%d+)", "[?&][iI][dD]=(%d+)" } do
		for digits in string.gmatch(body, pattern) do
			local id = tonumber(digits)
			if id and id > 0 and id ~= decalId then
				return id
			end
		end
	end
	return nil
end

function Decal.resolve(client: OpenCloud.Client, decalId: number): (number?, string?)
	local meta = client:request("GET", string.format("%s/asset-delivery-api/v1/assetId/%d", OpenCloud.BASE, decalId))
	if not meta.ok or type(meta.json) ~= "table" or type(meta.json.location) ~= "string" then
		return nil,
			string.format("asset-delivery lookup failed (HTTP %d): %s", meta.status, string.sub(meta.body, 1, 200))
	end
	-- The location is a signed CDN URL: never send the API key there.
	local content = client:request("GET", meta.json.location, { auth = false })
	if not content.ok then
		return nil, string.format("decal content download failed (HTTP %d)", content.status)
	end
	local imageId = Decal.parseImageId(content.body, decalId)
	if not imageId then
		return nil, "no image id found in the decal content"
	end
	return imageId, nil
end

return Decal
