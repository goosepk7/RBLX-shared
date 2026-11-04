--!strict
--[[
	Project lint (brief §9.4) for rules Selene cannot express.

	  lune run tools/lint [paths...]      default path: src

	Rules:
	  waitforchild-timeout  :WaitForChild(name) without a timeout can hang forever
	  remote-outside-net    RemoteEvent/RemoteFunction use outside the Net module
	  hardcoded-asset-id    "rbxassetid://123" literals; use Assets.get(name)
	  unknown-asset         Assets.get/image/sound/ref/applyImage("x") where x is not in any
	                        manifest (this repo's and Packages/RBLXShared's)
	  discarded-pcall       pcall(...) whose result is thrown away swallows errors

	Silence one line with a trailing or preceding comment: `-- lint-ignore: rule-name`.
	Generated AssetIds modules are skipped. Exit 1 on any finding.

	Game repos can add rules in tools/lint.config.json:
	  { "netPaths": ["src/ReplicatedStorage/Stilts/Net"], "extraManifests": [] }
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

export type Finding = { path: string, line: number, rule: string, message: string }

local Lint = {}

local REMOTE_PATTERNS = {
	'Instance%.new%(%s*"RemoteEvent"',
	'Instance%.new%(%s*"UnreliableRemoteEvent"',
	'Instance%.new%(%s*"RemoteFunction"',
	":FireServer%(",
	":FireClient%(",
	":FireAllClients%(",
	":InvokeServer%(",
	":InvokeClient%(",
	"%.OnServerEvent",
	"%.OnClientEvent",
	"%.OnServerInvoke",
	"%.OnClientInvoke",
}

local ASSET_CALL = 'Assets[%.:](%a+)%(%s*"([^"]+)"'
local ASSET_FUNCS = { get = true, image = true, sound = true, ref = true, applyImage = true, isPlaceholder = true }

export type Config = { netPaths: { string }, manifests: { string } }

local function startsWith(text: string, prefix: string): boolean
	return string.sub(text, 1, #prefix) == prefix
end

-- Removes comments and string contents' influence on comment detection, line by line.
-- Returns code-only lines (comments blanked) so patterns never match inside comments.
function Lint.stripComments(source: string): { string }
	local lines = string.split(source, "\n")
	local out: { string } = {}
	local inBlock: string? = nil -- closing delimiter, e.g. "]]" or "]==]"
	for i, line in lines do
		local code = ""
		local pos = 1
		while pos <= #line do
			if inBlock then
				local close = string.find(line, inBlock, pos, true)
				if close then
					pos = close + #inBlock
					inBlock = nil
				else
					pos = #line + 1
				end
			else
				local c = string.sub(line, pos, pos)
				if c == '"' or c == "'" or c == "`" then
					-- copy the string literal verbatim (patterns may need it), honouring escapes
					local j = pos + 1
					while j <= #line do
						local d = string.sub(line, j, j)
						if d == "\\" then
							j += 2
						elseif d == c then
							break
						else
							j += 1
						end
					end
					code ..= string.sub(line, pos, j)
					pos = j + 1
				elseif string.sub(line, pos, pos + 1) == "--" then
					local eq = string.match(line, "^%-%-%[(=*)%[", pos)
					if eq then
						inBlock = "]" .. eq .. "]"
						pos += 4 + #eq
					else
						pos = #line + 1
					end
				else
					code ..= c
					pos += 1
				end
			end
		end
		out[i] = code
	end
	return out
end

local function ignored(rawLines: { string }, index: number, rule: string): boolean
	local marker = "lint%-ignore:%s*([%w%-,%s]+)"
	for _, i in { index, index - 1 } do
		local line = rawLines[i]
		if line then
			local rules = string.match(line, marker)
			if rules then
				for name in string.gmatch(rules, "[%w%-]+") do
					if name == rule then
						return true
					end
				end
			end
		end
	end
	return false
end

function Lint.loadAssetNames(manifestPaths: { string }): { [string]: boolean }?
	local names: { [string]: boolean } = {}
	local any = false
	for _, path in manifestPaths do
		if fs.isFile(path) then
			any = true
			local decoded = serde.decode("json", fs.readFile(path))
			for _, entry in decoded.assets or {} do
				names[entry.name] = true
			end
		end
	end
	return if any then names else nil
end

function Lint.checkSource(path: string, source: string, config: Config, assetNames: { [string]: boolean }?): { Finding }
	local findings: { Finding } = {}
	local raw = string.split(source, "\n")
	local code = Lint.stripComments(source)
	local inNet = false
	for _, netPath in config.netPaths do
		if startsWith(path, netPath) then
			inNet = true
		end
	end

	local function add(line: number, rule: string, message: string)
		if not ignored(raw, line, rule) then
			table.insert(findings, { path = path, line = line, rule = rule, message = message })
		end
	end

	for i, line in code do
		-- WaitForChild with exactly one argument
		for args in string.gmatch(line, ":WaitForChild(%b())") do
			local inner = string.sub(args, 2, -2)
			local depth, commas = 0, 0
			for ch in string.gmatch(inner, ".") do
				if ch == "(" or ch == "{" then
					depth += 1
				elseif ch == ")" or ch == "}" then
					depth -= 1
				elseif ch == "," and depth == 0 then
					commas += 1
				end
			end
			if commas == 0 then
				add(i, "waitforchild-timeout", "WaitForChild without a timeout; pass one (e.g. 10) and handle nil")
			end
		end

		if not inNet then
			for _, pattern in REMOTE_PATTERNS do
				if string.find(line, pattern) then
					add(i, "remote-outside-net", "remotes go through the shared Net module")
					break
				end
			end
		end

		if string.find(line, "rbxassetid://%d") then
			add(i, "hardcoded-asset-id", 'hardcoded asset id; add it to the manifest and use Assets.get("name")')
		end

		if assetNames then
			for func, name in string.gmatch(line, ASSET_CALL) do
				if ASSET_FUNCS[func] and not assetNames[name] then
					add(i, "unknown-asset", string.format("%q is not in any asset manifest", name))
				end
			end
		end

		if string.match(line, "^%s*pcall%(") or string.match(line, "^%s*task%.spawn%(%s*pcall") then
			add(i, "discarded-pcall", "pcall result discarded; handle or log the error")
		end
	end
	return findings
end

local function collect(path: string, out: { string })
	if fs.isFile(path) then
		if string.match(path, "%.luau?$") then
			table.insert(out, path)
		end
		return
	end
	if not fs.isDir(path) then
		return
	end
	local names = fs.readDir(path)
	table.sort(names)
	for _, name in names do
		collect(path .. "/" .. name, out)
	end
end

function Lint.loadConfig(): Config
	local config: Config = {
		netPaths = { "src/Net" },
		manifests = { "assets/manifest.json", "Packages/RBLXShared/assets/manifest.json" },
	}
	local path = "tools/lint.config.json"
	if fs.isFile(path) then
		local decoded = serde.decode("json", fs.readFile(path))
		if type(decoded.netPaths) == "table" then
			config.netPaths = decoded.netPaths
		end
		for _, extra in decoded.extraManifests or {} do
			table.insert(config.manifests, extra)
		end
	end
	return config
end

function Lint.main(argv: { string }): number
	local roots = if #argv > 0 then argv else { "src" }
	local config = Lint.loadConfig()
	local assetNames = Lint.loadAssetNames(config.manifests)
	local files: { string } = {}
	for _, root in roots do
		collect(root, files)
	end
	local all: { Finding } = {}
	for _, file in files do
		if not string.find(file, "AssetIds%.luau$") then
			for _, finding in Lint.checkSource(file, fs.readFile(file), config, assetNames) do
				table.insert(all, finding)
			end
		end
	end
	for _, f in all do
		print(string.format("%s:%d: [%s] %s", f.path, f.line, f.rule, f.message))
	end
	print(string.format("%s  %d file(s), %d finding(s)", if #all == 0 then "PASS" else "FAIL", #files, #all))
	return if #all == 0 then 0 else 1
end

return Lint
