# Scriptser JSON control

Target: **{{APP_NAME}}** (`{{BUNDLE_ID}}`); generated skill: `scriptser-control`.

Run `python3 SKILL_DIRECTORY/scripts/scriptserctl.py METHOD [--params-file FILE | --params JSON]`.
`--params-file -` reads stdin. `--socket ABSOLUTE_PATH` selects an isolated test endpoint; otherwise the client uses `~/Library/Application Support/{{SUPPORT_NAME}}/control.sock`. `--timeout SECONDS` defaults to 15. Python 3 standard library only; no packages or network credentials.

The app must be running. `launch` requests `open -g {{APP_NAME}}` using the generated app target; poll `status` afterward. Launch may run enabled scripts marked `runAtLaunch`. It does not change that setting. Regenerate the skill after moving the app.

Responses: `{ "ok": true, "result": ... }` or `{ "ok": false, "error": { "code": "...", "message": "..." } }`. Exit 0 means an API operation was accepted/completed, 1 is an API error, 2 is client/transport failure. Bulk results contain per-script `ok`; inspect every entry. Process start and update acceptance do not prove successful completion. No mutation is retried automatically.

## Scripts

| Method | Parameters | Result / behavior |
| --- | --- | --- |
| `status` | none | Version, readiness, startup completion, counts, config directory, last error |
| `scripts.list` | none | IDs, names, notes, flags, tags, dates, execution state; omits commands |
| `scripts.get` | `id` | Definition including command/directory and state |
| `scripts.upsert` | For creation: `name`, `command`; optional `notes`, `workingDirectory`, `isEnabled`, `runAtLaunch`, `tags`. For edit: existing `id` and changed fields | Save only. Defaults: enabled, no launch autorun, empty notes/directory/tags. ID and creation date retained on edit |
| `scripts.run` | `id` | Start through the app's ProcessManager; disabled/empty/already-running targets fail |
| `scripts.stop` | `id` | Request normal termination; inspect returned state and poll before assuming exit |
| `scripts.end` | `id`, `expectedPID` | Force termination of the currently tracked PID; obtain PID from fresh get/list; stale/missing PID fails |
| `scripts.delete` | `id` | Remove definition. Running target must be stopped first |
| `scripts.run-all` | none | Run enabled, non-running scripts; per-script results |
| `scripts.stop-all` | none | Stop all managed scripts; per-script results |
| `scripts.output` | `id` | Captured stdout/stderr; bounded buffer, may include shell startup messages |
| `scripts.clear-output` | `id` | Clear captured output |
| `scripts.export` | absolute `path` | Write native JSON array to file, atomically; overwrites that path |
| `scripts.import` | absolute `path`, `strategy` | Read native exported JSON. `append` gives every imported script a fresh ID; `merge` updates matching IDs; `replace` replaces definitions and rejects removing running scripts |

Example parameters file for a new script (saving does not run it):

```json
{
  "name": "Service status",
  "notes": "Check the requested backend",
  "command": "node tools/status.mjs",
  "workingDirectory": "/absolute/project/path",
  "isEnabled": true,
  "runAtLaunch": false
}
```

Run after the user authorizes execution: `scripts.run --params '{"id":"UUID_FROM_RESPONSE"}'`. Poll `scripts.get` until `state.status` is `success`, `failed`, or `stopped`, then inspect `exitCode` and output. `started_persistence_failed` means the process started but the last-run timestamp failed to save: inspect status, never blindly rerun it.

API dates are ISO 8601. Import/export preserves Scriptser's existing native JSON date format (seconds since Apple's 2001 reference date); do not use API get/list output as an import file. Commands run using `/bin/zsh -ilc`, consistent with the app.

## Settings and skills

| Method | Parameters | Behavior |
| --- | --- | --- |
| `settings.get` | none | Language, login setting/status, output buffer size, skill directory |
| `settings.update` | optional `language` (`system`, `en`, `zh-Hans`), `launchAtLoginEnabled` boolean, `outputBufferSize` (1000–1000000), absolute `skillDirectory` | Validate supplied fields then update. macOS may return `requiresApproval` for login item; do not treat it as enabled |
| `skill.preview` | none | Render generated SKILL.md |
| `skill.generate` | optional absolute `directory` (parent skills folder) | Install/refresh bundled code skill. Default: saved skill directory. Accepts legacy generated UI skill; preserves unrelated additional files and rejects unrelated packages/symlinks |

## Updates and app lifecycle

| Method | Parameters | Behavior |
| --- | --- | --- |
| `updates.check` | none | Start GitHub latest stable release check; returns accepted |
| `updates.status` | none | `busy`, state/phase, current/latest version, progress, download path, release URL, last error, in-place install support |
| `updates.download` | absolute `path` | Requires available update; download and verify package to chosen path, returns accepted |
| `updates.install` | none | Requires available update and production app bundle; verifies package, replaces app, and restarts. Returns accepted; endpoint disconnects during restart |
| `app.quit` | none | Quit after replying, leaving managed processes running |

Poll `updates.status` until `busy` is false and inspect `lastError`. `state: current` means no newer stable version; `noRelease` means no stable release found; neither is a successful installation. During install, wait for the endpoint to return, then check `status.version`. Concurrent update operations return `busy`.

## Transport

One newline-terminated UTF-8 JSON request per Unix socket connection:
`{"version":1,"method":"scripts.list","params":{}}`.
Socket permissions are 0600, peers must share the app user's UID, and requests are limited to 1 MiB with a five-second framing deadline. The app uses a lock to protect its endpoint and recovers stale sockets after exit. There is no TCP service. `--socket` changes only the endpoint, not which app/config owns it.
