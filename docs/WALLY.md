# Wally registry (one-time setup for the owner)

Until this is done, both games consume RBLX-shared as a git submodule at `Packages/RBLXShared`,
which gives the same `require(ReplicatedStorage.Packages.RBLXShared)` path.

When you want the registry:
1. Create an empty GitHub repo `goosepk7/wally-index`.
2. Add a file `config.json` to it:
   ```json
   { "api": "https://<your-wally-registry-host>", "github_oauth_app_id": "<id>" }
   ```
   Wally needs a small registry server for publishing (`wally-registry-backend`). Hosting one is
   optional; the submodule route needs none of this.
3. Tell the coordinator; we switch games to `RBLXShared = "goosepk7/rblx-shared@0.x"` in their
   `wally.toml`. No code changes, because the import path is identical.
