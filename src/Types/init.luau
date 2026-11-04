--!strict
--[[
	Types: shared Luau types used across RBLXShared modules and both games.

	Pure types. Requiring this module returns an empty table and costs nothing at runtime:

	  local Types = require(Packages.RBLXShared).Types
	  type StageResult = Types.StageResult

	Ownership: each type is defined here once; modules re-export the ones they work with
	(Economy.Wallet is Types.Wallet). Changing a field is a breaking change (semver major).
]]

-- Roblox UserId.
export type UserId = number

-- Identifier for a configured currency, e.g. "Wins" or "Cash". Game-defined.
export type CurrencyId = string

--[[ Economy ]]

-- Static definition of a currency, supplied by the game's Config.
export type Currency = {
	id: CurrencyId,
	-- English display name; Loc keys come with the Loc module (v0.2).
	displayName: string,
	-- Whole numbers only. Fractional earnings (from multipliers) carry over between earns.
	-- Default true.
	integer: boolean?,
	-- Highest allowed balance (anti-overflow clamp). Default and maximum: Economy.MAX_BALANCE.
	max: number?,
	-- Balance a brand-new wallet starts with. Default 0.
	starting: number?,
	-- Mirror the balance into the Roblox player list (leaderstats). Default false.
	leaderstat: boolean?,
	-- Asset manifest name for the currency icon (Assets.get), e.g. "icon_wins".
	icon: string?,
}

-- Persisted per-currency state inside a player's wallet.
export type CurrencyState = {
	-- Spendable balance.
	balance: number,
	-- Earned since the last reset (rebirth). Drives gates such as "lifetime Wins".
	lifetime: number,
	-- Earned ever. Never reset; for analytics and all-time boards.
	allTime: number,
	-- Fractional remainder from multiplied earnings on integer currencies, in [0, 1).
	carry: number,
}

-- A timed multiplier owned by one player (for example a 30-minute 2x boost).
export type BoostState = {
	factor: number,
	-- Seconds of play time left. Counts down only while the player is in a server.
	remaining: number,
	-- Currencies the boost applies to; nil means all.
	currencies: { CurrencyId }?,
}

-- Persisted economy state. Lives inside the game's profile data (profile.data.wallet).
export type Wallet = {
	currencies: { [CurrencyId]: CurrencyState },
	boosts: { [string]: BoostState },
}

--[[ Data ]]

-- Session lock written into a profile while a server owns it.
export type SessionLock = {
	sessionId: string,
	jobId: string,
	placeId: number,
	-- os.time() when this session took the lock.
	lockedAt: number,
	-- os.time() of the owner's last successful write. Stale locks are reclaimed.
	heartbeatAt: number,
}

-- A durable record that a developer-product purchase was granted (idempotency by receipt).
export type ReceiptRecord = {
	purchaseId: string,
	productId: number,
	-- os.time() when it was granted.
	grantedAt: number,
}

-- Framework-owned metadata stored next to the game's data.
export type ProfileMeta = {
	-- Schema version of `data` (the game's migrations bring it up to date on load).
	schemaVersion: number,
	createdAt: number,
	updatedAt: number,
	-- Number of sessions that have loaded this profile.
	loadCount: number,
	session: SessionLock?,
	-- Set by another server asking the owner to release the lock.
	forceRelease: { sessionId: string, requestedAt: number }?,
	-- Most recent granted purchases, oldest first, bounded (Data.MAX_RECEIPTS).
	receipts: { ReceiptRecord },
}

-- The shape persisted for every player: the game's data plus framework metadata.
export type PlayerProfile<T> = {
	userId: UserId,
	-- DataStore key the profile lives under.
	key: string,
	data: T,
	meta: ProfileMeta,
}

--[[ Progression (consumed by v0.2 Progression/Leaderboards; produced by game systems) ]]

-- Server-authoritative outcome of one stage or challenge attempt.
export type StageResult = {
	-- Game-defined stage key, e.g. "pier:gapwalk:easy" or "greenfield:scout:3:seed".
	stageId: string,
	userId: UserId,
	-- Unique per attempt (GUID); lets analytics and anti-exploit correlate events.
	attemptId: string,
	completed: boolean,
	-- os.time() bounds of the attempt.
	startedAt: number,
	finishedAt: number?,
	-- Server-measured duration in seconds (nil when not completed).
	durationSeconds: number?,
	parSeconds: number?,
	-- Star or medal ids awarded on this attempt, e.g. { "clear", "underPar" }.
	awards: { string },
	-- Run qualifiers such as untouched, clean, noDismount. Absent means false.
	flags: { [string]: boolean },
}

--[[ Monetization ]]

-- MarketplaceService.ProcessReceipt's receiptInfo, typed.
export type PurchaseReceipt = {
	PurchaseId: string,
	PlayerId: UserId,
	ProductId: number,
	PlaceIdWherePurchased: number,
	CurrencySpent: number,
	-- Enum.CurrencyType in Roblox (left open so fakes can use strings).
	CurrencyType: any,
}

--[[ Assets ]]

export type AssetKind = "image" | "audio" | "animation" | "mesh" | "video"
export type AssetStatus = "pending" | "uploaded"

-- What Assets.get(name) returns. Code never hardcodes asset ids.
export type AssetRef = {
	name: string,
	kind: AssetKind,
	status: AssetStatus,
	assetId: number?,
	-- "rbxassetid://<id>" when uploaded; "" while pending (placeholder = true).
	uri: string,
	-- True while the asset is pending upload and a visible placeholder should render.
	placeholder: boolean,
}

return {}
