--!strict
--[[
	Admin (brief §3.3, §4): owner-only commands, a data inspector and a sim launcher, used from
	chat ("/admin grant me Wins 500") or from the Admin panel ("/admin" opens it).

	  -- Server
	  local admin = Shared.Admin.Server.new({
	      owners = { 123456 },                 -- UserIds; Studio is allowed too unless allowStudio = false
	      store = Profiles, economy = economy, analytics = analytics,
	      sims = require(ServerStorage.Stilts.Sims),   -- { Sim.Runner definitions }
	      teleport = function(player, target) ... end, -- optional: named spots
	  })
	  admin:register({ name = "event", description = "Start the flood event", run = function(ctx) ... end })

	  -- Client
	  Shared.Admin.Client.new({ screens = screens, loc = loc, area = area })

	Every command and query runs on the server and checks the caller's UserId; a non-owner
	calling the admin remotes is dropped and gets an AntiExploit strike. Every command, allowed
	or not, goes into the audit log the panel shows. Destructive commands (reset) need the word
	"confirm" as their last argument.
]]

local AntiExploit = require("./AntiExploit")
local Log = require("./Util/Log")
local Net = require("./Net")
local Roblox = require("./Util/Roblox")
local Signal = require("./Signal")
local SimRunner = require("./Sim/Runner")

export type ArgType = "player" | "number" | "integer" | "string" | "currency" | "choice" | "rest"

export type ArgSpec = {
	name: string,
	type: ArgType,
	optional: boolean?,
	options: { string }?, -- choice
}

export type Context = {
	caller: Player?, -- nil when run from server code
	admin: Server,
	reply: (message: string) -> (),
}

export type Command = {
	name: string,
	description: string,
	args: { ArgSpec }?,
	-- Returns (ok, message). May yield (it runs in the remote's handler thread).
	run: (ctx: Context, args: { [string]: any }) -> (boolean, string?),
}

export type AuditEntry = {
	at: number,
	userId: number,
	name: string,
	line: string,
	ok: boolean,
	message: string,
}

export type View = "players" | "inspect" | "diagnostics" | "flags" | "analytics" | "audit" | "commands" | "sims"

export type ServerOptions = {
	owners: { number },
	allowStudio: boolean?, -- default true: anyone in a Studio test session
	store: any?, -- Data.Store
	economy: any?,
	analytics: any?,
	antiExploit: any?, -- default AntiExploit.default()
	sims: { any }?, -- Sim.Runner definitions
	teleport: ((player: Player, target: string) -> (boolean, string?))?,
	players: any?,
	context: any?, -- Net context (tests)
	chatCommands: boolean?, -- default true in Roblox: /admin through TextChatService
	now: (() -> number)?,
	isStudio: (() -> boolean)?,
}

export type Server = {
	remotes: any,
	CommandRan: Signal.Signal<AuditEntry>,
	isOwner: (self: Server, player: Player?) -> boolean,
	register: (self: Server, command: Command | any) -> (),
	run: (self: Server, caller: Player?, line: string) -> (boolean, string),
	query: (self: Server, caller: Player?, view: View, arg: any) -> any,
	getAudit: (self: Server, limit: number?) -> { AuditEntry },
	commands: (self: Server) -> { { name: string, description: string, usage: string } },
}

local Admin = {}

Admin.VIEWS = { "players", "inspect", "diagnostics", "flags", "analytics", "audit", "commands", "sims" } :: { View }

local MAX_LINE = 200
local AUDIT_SIZE = 100

--- Splits a command line into words; "double quotes" keep spaces. `/admin` is optional.
-- Removes a leading "/admin" only as a whole word: "/adminx foo" keeps its first word.
local function stripPrefix(line: string): string
	local text = string.gsub(line, "^%s*", "")
	if string.sub(text, 1, 6) == "/admin" and (#text == 6 or string.match(string.sub(text, 7, 7), "%s")) then
		return (string.gsub(string.sub(text, 7), "^%s*", ""))
	end
	return text
end
Admin.stripPrefix = stripPrefix

function Admin.parse(line: string): { string }
	local words: { string } = {}
	local text = stripPrefix(line)
	local i = 1
	local n = #text
	while i <= n do
		local c = string.sub(text, i, i)
		if string.match(c, "%s") then
			i += 1
		elseif c == '"' then
			local close = string.find(text, '"', i + 1, true)
			local finish = close or (n + 1)
			table.insert(words, string.sub(text, i + 1, finish - 1))
			i = finish + 1
		else
			local finish = string.find(text, "%s", i) or (n + 1)
			table.insert(words, string.sub(text, i, finish - 1))
			i = finish
		end
	end
	return words
end

function Admin.usage(command: Command): string
	local parts = { command.name }
	for _, arg in command.args or {} :: { ArgSpec } do
		local label = if arg.type == "choice" and arg.options then table.concat(arg.options, "|") else arg.name
		table.insert(parts, if arg.optional then "[" .. label .. "]" else "<" .. label .. ">")
	end
	return table.concat(parts, " ")
end

-- Finds one player by "me", a UserId, or the start of a name / display name (case-insensitive).
function Admin.findPlayer(list: { any }, word: string, caller: any): (any, string?)
	local lower = string.lower(word)
	if lower == "me" then
		if caller then
			return caller, nil
		end
		return nil, `"me" needs a player`
	end
	local id = tonumber(word)
	if id then
		for _, p in list do
			if p.UserId == id then
				return p, nil
			end
		end
	end
	local exact, partial = {}, {}
	for _, p in list do
		local name, display = string.lower(p.Name), string.lower(p.DisplayName or p.Name)
		if name == lower or display == lower then
			table.insert(exact, p)
		elseif string.sub(name, 1, #lower) == lower or string.sub(display, 1, #lower) == lower then
			table.insert(partial, p)
		end
	end
	local found = if #exact > 0 then exact else partial
	if #found == 1 then
		return found[1], nil
	elseif #found > 1 then
		return nil, `"{word}" matches {#found} players; type more of the name`
	end
	return nil, `no player "{word}" in this server`
end

local function playersOf(options: ServerOptions): { any }
	local players: any = options.players or Roblox.service("Players")
	return players:GetPlayers()
end

local function parseArgs(
	options: ServerOptions,
	command: Command,
	words: { string },
	caller: any
): ({ [string]: any }?, string?)
	local out: { [string]: any } = {}
	local specs: { ArgSpec } = command.args or {}
	local index = 2
	for _, spec in specs do
		local word = words[index]
		if spec.type == "rest" then
			local rest = {}
			for i = index, #words do
				table.insert(rest, words[i])
			end
			if #rest == 0 and not spec.optional then
				return nil, "missing " .. spec.name .. ". Usage: " .. Admin.usage(command)
			end
			out[spec.name] = if #rest > 0 then table.concat(rest, " ") else nil
			index = #words + 1
			continue
		end
		if word == nil then
			if spec.optional then
				continue
			end
			return nil, "missing " .. spec.name .. ". Usage: " .. Admin.usage(command)
		end
		index += 1
		if spec.type == "player" then
			local player, err = Admin.findPlayer(playersOf(options), word, caller)
			if player == nil then
				return nil, err
			end
			out[spec.name] = player
		elseif spec.type == "number" or spec.type == "integer" then
			local n = tonumber(word)
			if n == nil or n ~= n or n == math.huge or n == -math.huge then
				return nil, `{spec.name} must be a number (got "{word}")`
			end
			if spec.type == "integer" and n ~= math.floor(n) then
				return nil, `{spec.name} must be a whole number`
			end
			out[spec.name] = n
		elseif spec.type == "currency" then
			local economy = options.economy
			if economy == nil then
				return nil, "no economy is bound to Admin"
			end
			-- "wins" finds "Wins": currency ids are usually capitalized.
			local capitalized = string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2)
			local found: string? = if economy:currency(word)
				then word
				elseif economy:currency(capitalized) then capitalized
				else nil
			if found == nil then
				return nil, `unknown currency "{word}"`
			end
			out[spec.name] = found
		elseif spec.type == "choice" then
			local options_ = spec.options or {}
			local lower = string.lower(word)
			if not table.find(options_, lower) then
				return nil, `{spec.name} must be one of {table.concat(options_, ", ")}`
			end
			out[spec.name] = lower
		else
			out[spec.name] = word
		end
	end
	if words[index] ~= nil then
		return nil, "too many arguments. Usage: " .. Admin.usage(command)
	end
	return out, nil
end

-- A copy safe to send to a client: plain data only, depth- and size-limited.
function Admin.snapshot(value: any, maxDepth: number?, maxEntries: number?): any
	local depthLimit = maxDepth or 8
	local entryLimit = maxEntries or 400
	local count = 0
	local function walk(v: any, depth: number): any
		local t = type(v)
		if t == "table" then
			if depth >= depthLimit then
				return "{…}"
			end
			local out = {}
			for k, child in v do
				count += 1
				if count > entryLimit then
					out["…"] = "truncated"
					break
				end
				out[tostring(k)] = walk(child, depth + 1)
			end
			return out
		elseif t == "number" or t == "string" or t == "boolean" then
			return v
		elseif t == "nil" then
			return nil
		end
		return tostring(v)
	end
	return walk(value, 0)
end

local S = Net.Schema

function Admin.remotes(options: { context: any?, guard: ((Player) -> boolean)? }?): any
	local opts: { context: any?, guard: ((Player) -> boolean)? } = options or {}
	return Net.namespace("RBLXAdmin", {
		Run = Net.clientFunction(
			S.string({ maxLength = MAX_LINE }),
			S.struct({ ok = S.boolean(), message = S.string({ maxLength = 2000 }) }),
			{ rateLimit = { rate = 4, burst = 8 }, timeout = 120 }
		),
		Query = Net.clientFunction(
			S.struct({
				view = S.enum(Admin.VIEWS),
				arg = S.optional(S.union(S.string({ maxLength = 64 }), S.number({ min = -1e15, max = 1e15 }))),
			}),
			S.any(),
			{ rateLimit = { rate = 4, burst = 10 }, timeout = 30 }
		),
		-- Server to owner: open the panel (from "/admin"), or show a command's reply.
		Open = Net.serverEvent(S.none()),
		Reply = Net.serverEvent(S.struct({ ok = S.boolean(), message = S.string({ maxLength = 2000 }) })),
	}, { context = opts.context, guard = opts.guard })
end

local Server = {}

function Server.new(options: ServerOptions): Server
	assert(type(options.owners) == "table", "Admin.Server.new needs owners (a list of UserIds)")
	local owners: { [number]: boolean } = {}
	for _, id in options.owners do
		owners[id] = true
	end
	local allowStudio = options.allowStudio ~= false
	local isStudio: () -> boolean = options.isStudio or Roblox.isStudio
	local now: () -> number = options.now or os.time
	local strikes: any = options.antiExploit
	local commands: { [string]: Command } = {}
	local order: { string } = {}
	local audit: { AuditEntry } = {}

	local server = { CommandRan = Signal.new() } :: Server

	function server.isOwner(_self: Server, player: Player?): boolean
		if player == nil then
			return false
		end
		if owners[player.UserId] then
			return true
		end
		return allowStudio and isStudio()
	end

	local function guard(player: Player): boolean
		if server:isOwner(player) then
			return true
		end
		local registry = strikes or AntiExploit.default()
		registry:strike(player, "admin.unauthorized", "called an admin remote")
		return false
	end

	server.remotes = Admin.remotes({ context = options.context, guard = guard })

	function server.register(_self: Server, command: Command | any)
		assert(type(command.name) == "string" and string.match(command.name, "^%l[%w%-]*$"), "Admin: bad command name")
		assert(type(command.run) == "function", "Admin: command needs run")
		if commands[command.name] == nil then
			table.insert(order, command.name)
		end
		commands[command.name] = command
	end

	local function record(caller: Player?, line: string, ok: boolean, message: string)
		local entry: AuditEntry = {
			at = now(),
			userId = if caller then caller.UserId else 0,
			name = if caller then caller.Name else "server",
			line = line,
			ok = ok,
			message = message,
		}
		table.insert(audit, entry)
		if #audit > AUDIT_SIZE then
			table.remove(audit, 1)
		end
		Log.info("Admin", `{entry.name}: {line} -> {if ok then "ok" else "failed"}: {message}`)
		server.CommandRan:Fire(entry)
	end

	function server.run(self: Server, caller: Player?, line: string): (boolean, string)
		line = string.sub(line, 1, MAX_LINE)
		if caller ~= nil and not self:isOwner(caller) then
			record(caller, line, false, "not an owner")
			return false, "Admin commands are for the game's owner."
		end
		local words = Admin.parse(line)
		local name = string.lower(words[1] or "help")
		local command = commands[name]
		if command == nil then
			local message = `unknown command "{name}". Try "help".`
			record(caller, line, false, message)
			return false, message
		end
		local args, err = parseArgs(options, command, words, caller)
		if args == nil then
			record(caller, line, false, err or "bad arguments")
			return false, err or "bad arguments"
		end
		local replies: { string } = {}
		local ctx: Context = {
			caller = caller,
			admin = self,
			reply = function(message: string)
				table.insert(replies, message)
			end,
		}
		local okCall, ok, message = pcall(command.run, ctx, args)
		local result: string
		local success: boolean
		if not okCall then
			success = false
			result = "error: " .. tostring(ok)
			Log.error("Admin", `{name} failed: {tostring(ok)}`)
		else
			success = ok == true
			result = message or (if success then "done" else "failed")
		end
		if #replies > 0 then
			result = table.concat(replies, "\n") .. "\n" .. result
		end
		record(caller, line, success, result)
		return success, result
	end

	function server.getAudit(_self: Server, limit: number?): { AuditEntry }
		local out: { AuditEntry } = {}
		for i = #audit, math.max(1, #audit - (limit or AUDIT_SIZE) + 1), -1 do
			table.insert(out, table.clone(audit[i]))
		end
		return out -- newest first
	end

	function server.commands(_self: Server): { { name: string, description: string, usage: string } }
		local out = {}
		for _, name in order do
			local command = commands[name]
			table.insert(out, { name = name, description = command.description, usage = Admin.usage(command) })
		end
		return out
	end

	local function profileData(userId: number): (any, string)
		local store = options.store
		if store == nil then
			return nil, "none"
		end
		local live = store:getByUserId(userId)
		if live then
			return { data = live.data, meta = live.meta }, "live"
		end
		local doc, err = store:viewAsync(userId)
		if doc then
			return doc, "saved"
		end
		return nil, err or "missing"
	end

	function server.query(self: Server, caller: Player?, view: View, arg: any): any
		if caller ~= nil and not self:isOwner(caller) then
			return nil
		end
		if view == "players" then
			local out = {}
			local registry = strikes or (if Roblox.isRoblox() then AntiExploit.default() else nil)
			for _, p in playersOf(options) do
				local record = if registry then registry:getRecord(p) else nil
				table.insert(out, {
					userId = p.UserId,
					name = p.Name,
					displayName = p.DisplayName or p.Name,
					loaded = if options.store then options.store:get(p) ~= nil else false,
					strikes = if record then record.strikes else 0,
					flagged = if record then record.flagged else false,
					playSeconds = if options.analytics then options.analytics:playSeconds(p) else nil,
				})
			end
			return out
		elseif view == "inspect" then
			local userId = tonumber(arg)
			if userId == nil and type(arg) == "string" then
				local player = Admin.findPlayer(playersOf(options), arg, caller)
				userId = if player then player.UserId else nil
			end
			if userId == nil then
				return { error = "Give a UserId or a player in this server." }
			end
			local doc, source = profileData(userId)
			if doc == nil then
				return { userId = userId, error = "No profile (" .. source .. ")." }
			end
			return { userId = userId, source = source, document = Admin.snapshot(doc) }
		elseif view == "diagnostics" then
			local out: { [string]: any } = {}
			if options.store then
				out.data = Admin.snapshot(options.store:getDiagnostics(), 4, 200)
			end
			if options.analytics then
				out.analytics = Admin.snapshot(options.analytics:getDiagnostics(), 3, 50)
			end
			if options.economy then
				out.economy = Admin.snapshot(options.economy:getDiagnostics(), 3, 100)
			end
			return out
		elseif view == "flags" then
			local registry = strikes or (if Roblox.isRoblox() then AntiExploit.default() else nil)
			return if registry then Admin.snapshot(registry:getFlagged(), 4, 300) else {}
		elseif view == "analytics" then
			if options.analytics == nil then
				return {}
			end
			return Admin.snapshot(options.analytics:getRecent(50, tonumber(arg)), 4, 600)
		elseif view == "audit" then
			return self:getAudit(50)
		elseif view == "commands" then
			return self:commands()
		elseif view == "sims" then
			local out = {}
			for _, def in options.sims or {} :: { any } do
				table.insert(out, { name = def.name, description = def.description or "" })
			end
			return out
		end
		return nil
	end

	-- Built-in commands.
	server:register({
		name = "help",
		description = "List commands",
		run = function()
			local lines = {}
			for _, c in server:commands() do
				table.insert(lines, c.usage .. ": " .. c.description)
			end
			return true, table.concat(lines, "\n")
		end,
	})

	server:register({
		name = "grant",
		description = "Add (or with a negative amount, take) currency",
		args = {
			{ name = "player", type = "player" },
			{ name = "currency", type = "currency" },
			{ name = "amount", type = "number" },
		},
		run = function(_ctx, args)
			local economy: any = options.economy
			if economy == nil then
				return false, "no economy is bound to Admin"
			end
			if not economy:isAttached(args.player) then
				return false, args.player.Name .. "'s wallet isn't loaded"
			end
			local balance = economy:balance(args.player, args.currency)
			local target = math.max(0, balance + args.amount)
			local ok, failure = economy:set(args.player, args.currency, target, "admin")
			if not ok then
				return false, "couldn't set the balance: " .. tostring(failure)
			end
			return true,
				`{args.player.Name} {args.currency}: {balance} -> {economy:balance(args.player, args.currency)}`
		end,
	})

	server:register({
		name = "reset",
		description = "Erase a player's save and kick them (type confirm)",
		args = { { name = "player", type = "player" }, { name = "confirm", type = "choice", options = { "confirm" } } },
		run = function(_ctx, args)
			local store = options.store
			if store == nil then
				return false, "no store is bound to Admin"
			end
			local userId = args.player.UserId
			local ok, err = store:removeAsync(userId)
			if not ok then
				return false, "couldn't erase the save: " .. tostring(err)
			end
			return true, `erased {args.player.Name}'s save ({userId}); they were kicked to rejoin fresh`
		end,
	})

	server:register({
		name = "kick",
		description = "Kick a player",
		args = { { name = "player", type = "player" }, { name = "reason", type = "rest", optional = true } },
		run = function(_ctx, args)
			args.player:Kick(args.reason or "Removed by the game's owner.")
			return true, "kicked " .. args.player.Name
		end,
	})

	server:register({
		name = "tp",
		description = "Teleport a player to another player or a named spot",
		args = { { name = "player", type = "player" }, { name = "target", type = "string" } },
		run = function(ctx, args)
			if options.teleport then
				local ok, message = options.teleport(args.player, args.target)
				if ok then
					return true, message or ("moved " .. args.player.Name)
				end
				if message then
					return false, message
				end
			end
			local target = Admin.findPlayer(playersOf(options), args.target, ctx.caller)
			local from = args.player.Character and args.player.Character:FindFirstChild("HumanoidRootPart")
			local to = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
			if from == nil or to == nil then
				return false, "both players need a character (or pass a named spot the game knows)"
			end
			args.player.Character:PivotTo(to.CFrame * CFrame.new(0, 0, 4))
			return true, `moved {args.player.Name} to {target.Name}`
		end,
	})

	server:register({
		name = "sim",
		description = "Run a balance sim on this server",
		args = { { name = "name", type = "string" } },
		run = function(_ctx, args)
			for _, def in options.sims or {} :: { any } do
				if def.name == args.name then
					local result = SimRunner.run(def, {
						output = function(line: string)
							Log.info("Admin.sim", line)
						end,
					})
					local summary = SimRunner.format(result)
					return result.ok, table.concat(summary, "\n")
				end
			end
			return false, `no sim "{args.name}". Registered: {#(options.sims or {})}`
		end,
	})

	server:register({
		name = "remote",
		description = "Turn a remote off or on in this server (kill switch)",
		args = { { name = "name", type = "string" }, { name = "state", type = "choice", options = { "on", "off" } } },
		run = function(_ctx, args)
			local ctx = options.context or Net.getDefaultContext()
			ctx:setEnabled(args.name, args.state == "on", "admin")
			return true, `{args.name} is {args.state} in this server`
		end,
	})

	-- Remote handlers.
	server.remotes.Run:handle(function(player: Player, line: string)
		local ok, message = server:run(player, line)
		return { ok = ok, message = string.sub(message, 1, 2000) }
	end)
	server.remotes.Query:handle(function(player: Player, request: { view: View, arg: any })
		return server:query(player, request.view, request.arg)
	end)

	-- "/admin" in chat: no words opens the panel; anything else runs as a command.
	local wantChat = options.chatCommands
	if wantChat == nil then
		wantChat = Roblox.isRoblox()
	end
	if wantChat then
		local textChat: any = Roblox.service("TextChatService")
		local command = Instance.new("TextChatCommand")
		command.Name = "RBLXSharedAdmin"
		command.PrimaryAlias = "/admin"
		command.Parent = textChat
		command.Triggered:Connect(function(source: TextSource, text: string)
			local player: any = (options.players or Roblox.service("Players")):GetPlayerByUserId(source.UserId)
			if player == nil or not server:isOwner(player) then
				return
			end
			local rest = stripPrefix(text)
			if rest == "" then
				server.remotes.Open:fire(player, nil)
				return
			end
			local ok, message = server:run(player, rest)
			server.remotes.Reply:fire(player, { ok = ok, message = string.sub(message, 1, 2000) })
		end)
	end

	return server
end

Admin.Server = Server

--- The client panel. `remotes` defaults to `Admin.remotes({ context = context })`.
Admin.Panel = require("@self/Panel")
Admin.Client = {
	new = function(options: { screens: any, loc: any, area: any?, remotes: any?, context: any?, name: string? }): any
		return Admin.Panel.client({
			screens = options.screens,
			loc = options.loc,
			area = options.area,
			remotes = options.remotes or Admin.remotes({ context = options.context }),
			name = options.name,
		})
	end,
}

return Admin
