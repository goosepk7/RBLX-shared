--!strict
--[[
	Fake MarketplaceService for purchase-flow tests.

	  local mps = T.Fakes.MarketplaceService.new()
	  mps.ProcessReceipt = Shop.processReceipt           -- the code under test
	  local receipt, decision = mps:purchaseProduct(player, 1234)
	  expect(decision).toBe(mps.Decision.PurchaseGranted)
	  mps:replay(receipt)                                -- same PurchaseId again: must not double-grant

	Like Roblox, receipts answered with NotProcessedYet (or that error) stay pending and are
	re-delivered by retryPending(), which models the player rejoining.

	Decisions: the fake compares against mps.Decision.PurchaseGranted / NotProcessedYet. Code
	under test should take these values as a dependency (default
	Enum.ProductPurchaseDecision.*) because Enum does not exist under lune.
]]

local Signal = require("../Signal")

export type Receipt = {
	PlayerId: number,
	ProductId: number,
	PurchaseId: string,
	CurrencySpent: number,
	CurrencyType: string,
	PlaceIdWherePurchased: number,
}

export type PlayerLike = { UserId: number }

export type Prompt = { kind: "product" | "gamepass" | "premium" | "subscription", userId: number, id: number }

export type ProductInfo = {
	Name: string,
	Description: string,
	PriceInRobux: number,
	ProductId: number?,
	TargetId: number?,
	IconImageAssetId: number,
}

export type FakeMarketplaceService = {
	Decision: { PurchaseGranted: any, NotProcessedYet: any },
	ProcessReceipt: ((receipt: Receipt) -> any)?,
	PromptGamePassPurchaseFinished: Signal.Signal<PlayerLike, number, boolean>,
	PromptProductPurchaseFinished: Signal.Signal<number, number, boolean>,

	UserOwnsGamePassAsync: (self: FakeMarketplaceService, userId: number, gamePassId: number) -> boolean,
	PlayerOwnsAsset: (self: FakeMarketplaceService, player: PlayerLike, assetId: number) -> boolean,
	PromptProductPurchase: (self: FakeMarketplaceService, player: PlayerLike, productId: number) -> (),
	PromptGamePassPurchase: (self: FakeMarketplaceService, player: PlayerLike, gamePassId: number) -> (),
	GetProductInfo: (self: FakeMarketplaceService, id: number, infoType: any?) -> ProductInfo,

	-- Test controls
	setDecisionValues: (self: FakeMarketplaceService, granted: any, notProcessed: any) -> (),
	defineProduct: (self: FakeMarketplaceService, id: number, info: { Name: string?, PriceInRobux: number? }?) -> (),
	grantPass: (self: FakeMarketplaceService, userId: number, gamePassId: number) -> (),
	revokePass: (self: FakeMarketplaceService, userId: number, gamePassId: number) -> (),
	failOwnershipChecks: (self: FakeMarketplaceService, times: number?) -> (),
	purchaseProduct: (
		self: FakeMarketplaceService,
		player: PlayerLike,
		productId: number,
		options: { purchaseId: string?, price: number? }?
	) -> (Receipt, any, string?),
	completeGamePassPrompt: (
		self: FakeMarketplaceService,
		player: PlayerLike,
		gamePassId: number,
		purchased: boolean
	) -> (),
	replay: (self: FakeMarketplaceService, receipt: Receipt) -> (any, string?),
	retryPending: (self: FakeMarketplaceService) -> { { receipt: Receipt, decision: any, error: string? } },
	pending: (self: FakeMarketplaceService) -> { Receipt },
	prompts: (self: FakeMarketplaceService) -> { Prompt },
	grantedCount: (self: FakeMarketplaceService, purchaseId: string?) -> number,
}

local MarketplaceService = {}

function MarketplaceService.new(): FakeMarketplaceService
	local passes: { [string]: boolean } = {}
	local products: { [number]: ProductInfo } = {}
	local pendingReceipts: { Receipt } = {}
	local promptLog: { Prompt } = {}
	local grants: { [string]: number } = {}
	local totalGrants = 0
	local ownershipFailures = 0
	local purchaseCounter = 0

	local service = {
		Decision = { PurchaseGranted = "PurchaseGranted", NotProcessedYet = "NotProcessedYet" },
		ProcessReceipt = nil,
		PromptGamePassPurchaseFinished = Signal.new(),
		PromptProductPurchaseFinished = Signal.new(),
	} :: FakeMarketplaceService

	local function passKey(userId: number, passId: number): string
		return tostring(userId) .. ":" .. tostring(passId)
	end

	-- Delivers a receipt the way Roblox does: pcall'd, pending unless explicitly granted.
	local function deliver(receipt: Receipt): (any, string?)
		local handler = service.ProcessReceipt
		if handler == nil then
			error("FakeMarketplaceService: ProcessReceipt is not set")
		end
		local ok, decision = pcall(handler, table.clone(receipt))
		local errorText: string? = nil
		if not ok then
			errorText = tostring(decision)
			decision = service.Decision.NotProcessedYet
		end
		local index: number? = nil
		for i, other in pendingReceipts do
			if other.PurchaseId == receipt.PurchaseId then
				index = i
				break
			end
		end
		if decision == service.Decision.PurchaseGranted then
			if index then
				table.remove(pendingReceipts, index)
			end
			grants[receipt.PurchaseId] = (grants[receipt.PurchaseId] or 0) + 1
			totalGrants += 1
		elseif index == nil then
			table.insert(pendingReceipts, receipt)
		end
		return decision, errorText
	end

	function service.UserOwnsGamePassAsync(_self: FakeMarketplaceService, userId: number, gamePassId: number): boolean
		if ownershipFailures > 0 then
			ownershipFailures -= 1
			error("HTTP 500 (Internal Server Error) (injected failure)", 0)
		end
		return passes[passKey(userId, gamePassId)] == true
	end

	function service.PlayerOwnsAsset(_self: FakeMarketplaceService, player: PlayerLike, assetId: number): boolean
		return passes[passKey(player.UserId, assetId)] == true
	end

	function service.PromptProductPurchase(_self: FakeMarketplaceService, player: PlayerLike, productId: number)
		table.insert(promptLog, { kind = "product", userId = player.UserId, id = productId })
	end

	function service.PromptGamePassPurchase(_self: FakeMarketplaceService, player: PlayerLike, gamePassId: number)
		table.insert(promptLog, { kind = "gamepass", userId = player.UserId, id = gamePassId })
	end

	function service.GetProductInfo(_self: FakeMarketplaceService, id: number, _infoType: any?): ProductInfo
		local info = products[id]
		if not info then
			return {
				Name = "Product " .. tostring(id),
				Description = "",
				PriceInRobux = 0,
				ProductId = id,
				TargetId = id,
				IconImageAssetId = 0,
			}
		end
		return table.clone(info)
	end

	function service.setDecisionValues(self: FakeMarketplaceService, granted: any, notProcessed: any)
		self.Decision = { PurchaseGranted = granted, NotProcessedYet = notProcessed }
	end

	function service.defineProduct(
		_self: FakeMarketplaceService,
		id: number,
		info: { Name: string?, PriceInRobux: number? }?
	)
		local i: { Name: string?, PriceInRobux: number? } = info or {}
		products[id] = {
			Name = i.Name or ("Product " .. tostring(id)),
			Description = "",
			PriceInRobux = i.PriceInRobux or 0,
			ProductId = id,
			TargetId = id,
			IconImageAssetId = 0,
		}
	end

	function service.grantPass(_self: FakeMarketplaceService, userId: number, gamePassId: number)
		passes[passKey(userId, gamePassId)] = true
	end

	function service.revokePass(_self: FakeMarketplaceService, userId: number, gamePassId: number)
		passes[passKey(userId, gamePassId)] = nil
	end

	function service.failOwnershipChecks(_self: FakeMarketplaceService, times: number?)
		ownershipFailures = times or 1
	end

	function service.purchaseProduct(
		_self: FakeMarketplaceService,
		player: PlayerLike,
		productId: number,
		options: { purchaseId: string?, price: number? }?
	): (Receipt, any, string?)
		local o: { purchaseId: string?, price: number? } = options or {}
		purchaseCounter += 1
		local info = products[productId]
		local receipt: Receipt = {
			PlayerId = player.UserId,
			ProductId = productId,
			PurchaseId = o.purchaseId or string.format("fake-%d-%d-%d", player.UserId, productId, purchaseCounter),
			CurrencySpent = o.price or (if info then info.PriceInRobux else 0),
			CurrencyType = "Robux",
			PlaceIdWherePurchased = 0,
		}
		local decision, errorText = deliver(receipt)
		service.PromptProductPurchaseFinished:Fire(player.UserId, productId, true)
		return receipt, decision, errorText
	end

	function service.completeGamePassPrompt(
		_self: FakeMarketplaceService,
		player: PlayerLike,
		gamePassId: number,
		purchased: boolean
	)
		if purchased then
			passes[passKey(player.UserId, gamePassId)] = true
		end
		service.PromptGamePassPurchaseFinished:Fire(player, gamePassId, purchased)
	end

	function service.replay(_self: FakeMarketplaceService, receipt: Receipt): (any, string?)
		return deliver(receipt)
	end

	function service.retryPending(
		_self: FakeMarketplaceService
	): { { receipt: Receipt, decision: any, error: string? } }
		local results = {}
		for _, receipt in table.clone(pendingReceipts) do
			local decision, errorText = deliver(receipt)
			table.insert(results, { receipt = receipt, decision = decision, error = errorText })
		end
		return results
	end

	function service.pending(_self: FakeMarketplaceService): { Receipt }
		return table.clone(pendingReceipts)
	end

	function service.prompts(_self: FakeMarketplaceService): { Prompt }
		return table.clone(promptLog)
	end

	-- How many times a receipt was acknowledged as granted (by id, or in total). Note this
	-- counts acknowledgements; idempotency tests should also assert the reward was applied once.
	function service.grantedCount(_self: FakeMarketplaceService, purchaseId: string?): number
		if purchaseId then
			return grants[purchaseId] or 0
		end
		return totalGrants
	end

	return service
end

return MarketplaceService
