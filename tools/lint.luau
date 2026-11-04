--!strict
-- Project lint entry point. Rules and options: tools/lib/lint.luau.
--   lune run tools/lint [paths...]

local process = require("@lune/process")

local Lint = require("./lib/lint")

process.exit(Lint.main(process.args))
