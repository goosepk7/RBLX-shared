--!strict
--[[
	Tiny argv parser for lune tools: `--flag`, `--key value`, `--key=value`, positionals.
]]

export type Args = {
	flags: { [string]: string | boolean },
	positional: { string },
	has: (self: Args, name: string) -> boolean,
	string: (self: Args, name: string, default: string?) -> string?,
	number: (self: Args, name: string, default: number?) -> number?,
}

local Args = {}

function Args.parse(argv: { string }, valueFlags: { string }?): Args
	local takesValue: { [string]: boolean } = {}
	for _, name in valueFlags or {} do
		takesValue[name] = true
	end
	local flags: { [string]: string | boolean } = {}
	local positional: { string } = {}
	local i = 1
	while i <= #argv do
		local arg = argv[i]
		local key, value = string.match(arg, "^%-%-([%w%-_]+)=(.*)$")
		if key then
			flags[key] = value
		else
			local name = string.match(arg, "^%-%-([%w%-_]+)$")
			if name then
				if takesValue[name] and argv[i + 1] ~= nil then
					flags[name] = argv[i + 1]
					i += 1
				else
					flags[name] = true
				end
			else
				table.insert(positional, arg)
			end
		end
		i += 1
	end

	local self = { flags = flags, positional = positional } :: Args

	function self.has(_self: Args, name: string): boolean
		return flags[name] ~= nil
	end

	function self.string(_self: Args, name: string, default: string?): string?
		local v = flags[name]
		if type(v) == "string" then
			return v
		end
		return default
	end

	function self.number(_self: Args, name: string, default: number?): number?
		local v = flags[name]
		if type(v) == "string" then
			return tonumber(v) or default
		end
		return default
	end

	return self
end

return Args
