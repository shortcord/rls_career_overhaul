# AGENTS.md

BeamNG.drive career-overhaul mod: Lua game extensions plus a Vue UI, shipped as a mod ZIP. There is no standalone app build, npm package, or dev server.

## Commands

Run from the repository root.

- Fast dev loop (the game reads the unpacked copy directly):

  ```sh
  rsync -avh --delete --exclude='.git/' --filter=':- .gitignore' --filter=":- .rsyncignore" "$(pwd)/" "$HOME/.local/share/BeamNG/BeamNG.drive/current/mods/unpacked/rls_career_overhaul_<version>/"
  ```

- Install a built ZIP: `install "./dist/rls_career_overhaul_v<version>.zip" "$HOME/.local/share/BeamNG/BeamNG.drive/current/mods/" --mode=0600` (also in `DEV.md`).
- Build a release: `tools/build_release.sh --version <version>`; artifacts go to `dist/`. Use `--tag v<version> --changelog-from-git` for a release. CI runs the same script on `v*` tags.
- The manifest records `git HEAD`, not the working tree. Commit before a release build or the recorded source SHA will be stale.
- Local check: `lua tools/test_hibernation_logging.lua` (also passes under `luajit`). There is no test runner, linter, or typecheck script in this checkout.
- `opencode.json` configures a `beamng` MCP server at `http://127.0.0.1:29292/mcp`; it only works while that local bridge is running.

## Architecture

- `scripts/rls_career_overhaul/modScript.lua` is the only entrypoint. It defers `overhaul_shell_extensionManager`, which owns startup, scopes, extension loading and teardown.
- `lua/ge/extensions/overhaul/` is game-side code; `lib/` contains private helpers loaded with `require("overhaul/...")`, not extensions. `lua/vehicle/` is vehicle-side code; `lua/common/overhaul/` is shared.
- `gameplay/overhaul/**/*.json` is runtime data read through BeamNG's VFS. There is no central roster: `lib/career/manifest.lua` scans `career/modules/` and `career/owners/` from disk.
- Adding a career module or shell owner means adding its JSON manifest plus the Lua file. The manifest `id` must equal BeamNG's extension name: `/` becomes `_`, and existing `_` becomes `__` (`overhaul/career/economy/bank` -> `overhaul_career_economy_bank`). Owner JSON also controls load order, scopes, demand loading and private-module policy.
- Loaded extensions are global tables named after the extension; use `optional(name)` or `rawget(_G, name)` for soft dependencies instead of assuming another owner is loaded.
- The current UI is Vue under `ui/ui-vue/mods/rls_career_overhaul/`, loaded from its `index.js`. `ui/modules/` and `ui/modModules/` are the older Angular/shared UI that it still imports. Routes, phone apps, computer functions and business types are declared in `gameplay/overhaul/*.json` and discovered at runtime.

## Local skills

```xml
<available_skills>
  <skill>
    <name>beamng-mods</name>
    <description>Build and debug BeamNG.drive and BeamMP mods, resources, and server plugins using Lua. Use this skill whenever the user mentions BeamNG modding, BeamMP, Resources/Server, Resources/Client, modScript.lua, lua/ge/extensions, extensions.load, MP.RegisterEvent, AddEventHandler, client/server event wiring, custom vehicles, gameplay scripts, or BeamNG Lua hooks.</description>
  </skill>
</available_skills>
```

Canonical source: `.agents/skills/beamng-mods/SKILL.md`, with API references in `references/` and working examples in `examples/`. `.claude/skills/beamng-mods` and `.hermes/skills/beamng-mods` are symlinks to it.

## Unit Test Generation

This project uses unit test generation skills.

### Available Skills

```xml
<available_skills>
  <skill>
    <name>generate-tests</name>
    <description>Use when the user asks to generate, create, write, or add unit tests for existing code, or to cover a class, method, or file with tests — including Java targets using JUnit 5, Mockito, or AssertJ. Not for analysis-only requests that stop at listing test cases.</description>
  </skill>
  <skill>
    <name>generate-test-cases</name>
    <description>Use when the user asks to analyze code for test coverage, list what test cases are needed, or review testing strategy — WITHOUT generating actual test code.</description>
  </skill>
</available_skills>
```
### Workflow

When asked to write tests for a target, run the two skills in order — do not go
straight to `generate-tests`:

1. Invoke `generate-test-cases <target>`. Its Given-When-Then list is the plan, and
   it stays visible so the tests can be checked against it.
2. Invoke `generate-tests <target>` and generate from **that** list. Do not re-analyse
   the target from scratch; name any case you add or drop, and why.

Stop after step 1 only when the user asked for the analysis alone. A user who runs
`/generate-tests` directly still gets the list first — the skill prints its own plan
before writing code.

### Key Principles

- INCLUDE: Each code branch, unique return value, each exception type
- EXCLUDE: Duplicate scenarios, collection size variations, speculative cases
- Format: `{method}_{state}_{outcome}` naming
- Structure: Given-When-Then with `actual`/`expected` prefixes

## Generated files and build output

- `ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career/utils/builtinCoreUi.js`, `builtinBusinessTypes.js`, `builtinComputerFunctions.js`, `builtinPhoneRoutes.js` and `luaScopes.js` are generated snapshots of `gameplay/overhaul` JSON. Edit the source JSON, not these files. Their generators live under `tests/support/`, which is not in this checkout.
- `dist/` is build output and is gitignored; do not edit or commit it.

## Constraints and gotchas

- The release ZIP contains only `art gameplay levels locales lua music scripts settings ui vehicles` plus two `licenses/tyre-thermals-*` files, per `tools/build_release.sh`. A new top-level shipped directory must be added to `CONTENT_DIRS`; docs, tools and `.github` never ship.
- `gameplay/overhaul/version.json` is the version source. The build script rewrites it in the staging copy only. The game-version gate is `SUPPORTED_GAME_MINOR_VERSION` in `shell/extensionManager.lua`.
- Runtime is LuaJIT: stay under its 200-local and 60-upvalue limits per function, and do not yield across `pcall`.
- Preserve existing license headers. New original code uses AGPL-3.0-only plus the BeamNG additional permission; BeamNG-derived files keep bCDDL. See `CONTRIBUTING.md` and `licenses/`.
- Save-shape changes must keep existing saves working; see `career/saveMigration.lua` and `lib/save/partMigration040.lua`.
- `main` is the public branch. Accepted changes are ported to a separate development repository, so do not assume dev-only `/tests` fixtures or generators exist here.

## Style

- Lua: 2-space indent; module files follow `local M = {}` ... `return M` and the header/comment style of neighboring files.
- Vue/JS: use the mod's `.prettierrc.json` (2 spaces, double quotes, semicolons, 120 columns).