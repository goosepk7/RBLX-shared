# Tooling

All tools are lune scripts, run from the repo root. In a game repo, run the same scripts from
the submodule: `lune run Packages/RBLXShared/tools/<tool>`; they read the game's own
`assets/manifest.json` and write the ids module named in its `assets/config.json`.

| Command | What it does |
|---|---|
| `lune run tests [filter]` | Unit tests (`tests/**/*.spec.luau`). |
| `lune run sims [filter]` | Sims (`sims/**/*.sim.luau`), outputs in `sims/out/`. |
| `lune run tools/lint [paths]` | Project lint: WaitForChild without timeout, remotes outside Net, hardcoded asset ids, unknown asset names, discarded pcall. Silence a line with `-- lint-ignore: <rule>`. |
| `lune run tools/gen_asset_ids [--check]` | Regenerate `AssetIds.luau` from the manifest (`--check` for CI). |
| `lune run tools/verify_assets [--fix-hashes] [--remote] [--release]` | Validate the manifest, files, hashes and ids module; `--remote` confirms ids on Roblox; `--release` fails while anything is pending. |
| `lune run tools/upload_assets --all [--dry-run]` | Upload pending and changed assets via Open Cloud, write ids back, regenerate ids. |
| `lune run tools/resolve_decals [--studio-script \| --apply ids.json]` | Finish images left `unresolved` (Decal uploaded, Image id unknown) without re-uploading. |
| `lune run tools/backup_profiles --universe <id> --datastore <name>` | Back up every player profile via Open Cloud (`--restore <folder> --key <key>` puts one back). See [Profile backups](#profile-backups). |
| `tools/ci/typecheck.sh` | Strict luau-lsp type check (needs `lune setup` first). |

## Asset manifest

`assets/manifest.json`:

```json
{
  "assets": [
    {
      "name": "icon_wins",
      "kind": "image",
      "path": "assets/icons/png/256/icon_wins.png",
      "sourceFile": "assets/icons/svg/icon_wins.svg",
      "source": "generated",
      "status": "pending",
      "assetId": null,
      "sha256": "…"
    }
  ],
  "version": 1
}
```

| Field | Meaning |
|---|---|
| `name` | Unique snake_case id used in code. Size variants use a suffix: `icon_wins_64`. |
| `kind` | `image`, `audio`, `animation`, `mesh`, `video`. |
| `path` | The file that gets uploaded. Not needed for `creator-store`. |
| `sourceFile` | Editable source the file is built from (SVG, synth script). Optional. |
| `source` | `generated` (default), `creator-store` (an existing Roblox id, no upload), `manual`. |
| `status` / `assetId` | `pending` + `null`, `unresolved` + `null` (images only, see below), or `uploaded` + the numeric id. For images `assetId` is always the **Image** id. |
| `decalId` | Images only: the Decal id Open Cloud returned on upload. Never used at runtime. |
| `sha256` | Hash of `path`. For uploaded entries a mismatch means the file changed and needs re-upload. |
| `displayName`, `meta` | Optional (name on Roblox; bpm/key/loop notes). |

Workflow after editing assets: `lune run tools/verify_assets --fix-hashes`, then
`lune run tools/gen_asset_ids`. CI runs `verify_assets` and fails on drift.

## Day-one upload (owner)

After publishing, create an Open Cloud API key at
[create.roblox.com/credentials](https://create.roblox.com/credentials) with the **Assets**
API (read + write) for your account or group, then in each repo:

```sh
export ROBLOX_API_KEY=...            # never commit this
export ROBLOX_CREATOR_USER_ID=...    # or ROBLOX_CREATOR_GROUP_ID=...
lune run tools/upload_assets --all
lune run tools/verify_assets --remote
```

Commit the updated `assets/manifest.json` and `AssetIds.luau`. Animations are listed with
manual steps: the Assets API does not accept them.

### Images: Decal id vs Image id

Open Cloud uploads images as `Decal` assets, but `ImageLabel.Image` needs the id of the Image
the Decal wraps. `upload_assets` stores the returned id as `decalId`, then asks Asset Delivery
(`/asset-delivery-api/v1/assetId/<decalId>`) for the Decal's content and reads the texture id
out of it. Only then does the entry become `uploaded` with `assetId` = the Image id. If that
step fails the entry is saved as `unresolved` (it renders as a placeholder, like pending) and:

```sh
lune run tools/resolve_decals                    # retry through Open Cloud
lune run tools/resolve_decals --studio-script    # or: paste the printed script into Studio's command bar
lune run tools/resolve_decals --apply ids.json   # ...and apply the JSON it prints
```

`verify_assets` rejects an uploaded image whose `assetId` equals its `decalId`, and
`--release` fails while anything is `unresolved`.

**Not yet verified against live Roblox** (no key until publish). The create, poll and resolve
sequence is covered by an end-to-end test against a local mock of the API, but the real
endpoint's scopes and the Decal content format are assumptions. **On the first real run,
spot-check one icon in Studio** (an ImageLabel with the new `assetId` must show the icon) and
run `verify_assets --remote`, which warns if Roblox reports a type other than `Image`.

## Profile backups

`tools/backup_profiles` reads every key of a profile data store through the Open Cloud data
stores API (v2) and writes `<out>/<datastore>/<UTC date>/entries.ndjson`, one line per entry
with its value, users, attributes and revision, plus `summary.json` (counts and any keys it
couldn't read). It exits 1 if anything failed, so a scheduled run shows up red.

The key needs the **universe-datastores.objects:list** and **universe-datastores.objects:read**
scopes for the experience (add **universe-datastores.objects:update** only on a key used for
restores), and an IP allowlist of `0.0.0.0/0` for GitHub Actions.

```sh
export ROBLOX_API_KEY=...          # never commit this
export ROBLOX_UNIVERSE_ID=...      # or pass --universe
lune run tools/backup_profiles --datastore Stilts_Profiles --out backups
```

Daily run: add this workflow to each game repo, with the key as the `ROBLOX_API_KEY` secret and
the experience id as the `ROBLOX_UNIVERSE_ID` variable. The game's `rokit.toml` must pin lune.

```yaml
# .github/workflows/backup-profiles.yml
name: Backup profiles
on:
  schedule:
    - cron: "17 6 * * *" # daily, 06:17 UTC
  workflow_dispatch:
permissions:
  contents: read
jobs:
  backup:
    runs-on: ubuntu-latest
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true
      - uses: CompeyDev/setup-rokit@v0.2.1
      - name: Back up profiles
        env:
          ROBLOX_API_KEY: ${{ secrets.ROBLOX_API_KEY }}
          ROBLOX_UNIVERSE_ID: ${{ vars.ROBLOX_UNIVERSE_ID }}
        run: lune run Packages/RBLXShared/tools/backup_profiles --datastore Stilts_Profiles --out backups
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: profiles-${{ github.run_id }}
          path: backups/
          retention-days: 30
```

Backups hold player progress and user ids: keep the game repos private.

Restoring one player (support fix, never in bulk):

```sh
lune run tools/backup_profiles --datastore Stilts_Profiles --restore backups/Stilts_Profiles/2026-11-04 --key Player_123
```

The restore reads the current value first and refuses while a server holds a live session lock
(the player is online; `--force` overrides). It clears the backup's own lock so the next server
loads it at once, writes with the current `etag` so a concurrent save makes it fail instead of
being overwritten, and lists any purchases in the current save that the backup doesn't have, so
they can be granted again by hand.

**Not yet verified against live Roblox** (no key until publish). Backup and restore are covered
by unit tests and an end-to-end test against a local mock of the API. On the first real run,
check that `summary.json`'s `saved` matches the number of players who have played.
