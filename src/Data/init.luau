--!strict
--[[
	Data: player profiles that don't lose progress (brief §3.2).

	  local Data = Shared.Data
	  local Profiles = Data.Store.new({
	  	name = "Stilts_Profiles",
	  	version = 1,
	  	template = Template,          -- the brand-new player's data
	  	migrations = Migrations,      -- { [2] = function(data) ... end, ... }
	  })
	  Profiles:bindPlayers()

	  MarketplaceService.ProcessReceipt = function(receipt)
	  	return Profiles:processReceipt(receipt, Products.grant)
	  end

	Session locking, autosave, retries, migrations, shutdown flush and idempotent receipts are in
	Data/Store.luau. Data.getDiagnostics() feeds the Admin panel's DataDiagnostics view, and
	tools/backup_profiles.luau takes daily backups through Open Cloud.
]]

local Document = require("@self/Document")
local Retry = require("@self/Retry")
local Serialize = require("@self/Serialize")
local Store = require("@self/Store")
local Types = require("./Types")

export type Profile<T> = Store.Profile<T>
export type Store<T> = Store.Store<T>
export type StoreOptions<T> = Store.StoreOptions<T>
export type BindOptions = Store.BindOptions
export type KickMessages = Store.KickMessages
export type LoadError = Store.LoadError
export type ReleaseReason = Store.ReleaseReason
export type StoreDiagnostics = Store.StoreDiagnostics
export type ProfileDiagnostics = Store.ProfileDiagnostics
export type Document = Document.Document
export type ProfileMeta = Types.ProfileMeta
export type PlayerProfile<T> = Types.PlayerProfile<T>

local Data = {}

Data.Store = {
	new = Store.new,
}

-- Granted PurchaseIds kept per profile (oldest dropped first).
Data.MAX_RECEIPTS = Store.MAX_RECEIPTS
-- Roblox's per-key limit, in encoded characters.
Data.MAX_SIZE = Serialize.MAX_SIZE

-- (ok, path?, reason?, size?): can this value be stored in a DataStore as is?
Data.check = Serialize.check
Data.estimateSize = Serialize.estimateSize
Data.isRetryable = Retry.isRetryable

-- Diagnostics for every store in this server, for the Admin panel's DataDiagnostics view.
function Data.getDiagnostics(): { StoreDiagnostics }
	local list: { StoreDiagnostics } = {}
	for _, store in Store.all() do
		table.insert(list, store:getDiagnostics())
	end
	return list
end

return Data
