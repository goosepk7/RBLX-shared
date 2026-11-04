# Contributing to RBLX-shared

## Setup (once)
1. Install [rokit](https://github.com/rojo-rbx/rokit), then run `rokit install` in the repo.
2. `lune setup` (editor types for lune scripts).
3. Optional: `pip install pre-commit && pre-commit install`.

## Everyday commands
| What | Command |
|---|---|
| Run all tests | `lune run tests` |
| Run matching tests | `lune run tests "Clock"` |
| Format | `stylua src tests sims tools` |
| Lint | `selene src tests sims tools` |
| Type check | `tools/ci/typecheck.sh` (after `lune setup`) |
| Build a place | `rojo build dev.project.json -o build/dev.rbxl` |

CI runs all of these on every PR; red CI blocks merge.

## Rules for code in `src/`
- `--!strict` on every file.
- Require siblings with relative strings: `require("./Types")`, children from an `init.luau` with
  `require("@self/Child")`, parents with `require("../Assets")`. Never `script.Parent` chains.
- Nothing runs at require time except building tables. No `game:GetService`, no `task.spawn`,
  no `Enum` reads at the top level. Take services as constructor dependencies with a lazy
  default, e.g. `deps.dataStoreService or game:GetService("DataStoreService")` inside `new`.
- Nothing game-specific. If a game needs it, it belongs here in a generic form.
- Add each new top-level module to `src/init.luau` (one line).

## Tests
- Files: `tests/<Module>/*.spec.luau`. Register cases when required:

```luau
local T = require("@shared/Test")
T.describe("Economy.earn", function()
	T.it("adds to the balance", function()
		T.expect(1 + 1).toBe(2)
	end)
end)
```

- Matchers: `toBe`, `toEqual` (deep), `toBeNear`, `toBeTruthy`, `toBeFalsy`, `toBeNil`, `toBeType`,
  `toBeGreaterThan(OrEqual)`, `toBeLessThan(OrEqual)`, `toContain`, `toHaveLength`, `toMatch`,
  `toThrow(substring?)`. Negate with `.never`.
- Use `T.Clock` for anything time-based and `T.Fakes.*` for Roblox services. Never sleep for real.
- Every bug fix starts with a failing test.

## Commits
Conventional commits scoped by module: `feat(shared/net): ...`, `fix(shared/test): ...`.
