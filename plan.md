# HackCode — Implementation Plan (living)

_Last updated: 2026-10-21 · version 3.1_

## Current status
Native SwiftUI app restructured into a Swift package (`HackCodeKit` core + `HackCode` app + tests).
Builds with zero warnings (Swift 6 strict concurrency); **71/71 tests pass**; the release `HackCode.app` builds and launches;
all three modules verified visually and against the live NVIDIA API.

## Audit of the 2.1 baseline (Stage 1)
| Area | Finding | Resolution |
|---|---|---|
| Build | Flat `swiftc` script; 6 home-grown test suites passed | Swift package, Swift Testing suite |
| AI execution | Model returned shell strings; denylist validator; `find`/`defaults`/unknown tools runnable; low risk auto-executed | Closed operation registry, typed args, local risk, explicit RUN + approval |
| LLMService | Model `meta/llama-3.2-11b-vision-instruct` (not Nemotron); regex JSON extraction; key-missing returned as fake success | Nemotron-3 via verified ID, strict schema, typed errors |
| Security audit | Severity assigned by the model; remediation split commands on spaces; verification via model output | Deterministic evaluators, registered remediation ops, re-check verification |
| Network scanner | Ping-swept / port-scanned other LAN hosts | Removed (out of local defensive scope) |
| Process monitor | `sh -c "ps … | head"`; top 20 only | libproc + ps fallback (constant args), full list, history |
| Info.plist | `NSAllowsArbitraryLoads = true` | Removed |
| UI | Matrix rain, cyan/red themes per mode, codehack "unlock" gating | Unified restrained design system, three-module navigation |

## Completed features (verified)
| Feature | Acceptance criteria | Evidence |
|---|---|---|
| Execution boundary | Unknown ops rejected; typed/range/regex validation; local risk; approval required ≥ ELEVATED; single execution; re-validation; audit logged | `ExecutionPolicyTests`, `CommandExecutorTests`, `PathPolicyTests` |
| Process runner | No shell; minimal env; timeout & cancel kill the process group; output cap; Seatbelt denies writes & network | `ProcessRunnerTests` (real harmless binaries) |
| Nemotron-3 integration | Live model returns schema-v1 JSON; auth/404/429/5xx mapped; retries; SSE streaming; reasoning discarded; key never in body/logs | `LLMServiceTests` (mocked) + live run 2026-10-21 with `nvidia/nemotron-3-ultra-550b-a55b` (plan, explanation 1012 chars, analysis 1263 chars) |
| SYS.ADMIN | Plan/rejections/exact command/risk basis shown; RUN/approve/deny/cancel; streaming output; elapsed time; copy; "why?" basis; AI explain; offline `/ops` `/run`; history ↑↓; bounded transcript | Snapshots 02–05; live risky request → only ELEVATED terminate staged, folder deletion not proposed |
| MONITOR | Real CPU/mem/swap/pressure/disk/net; full process list; sort/filter/scope; detail + CPU history; pause/interval; stale indicator; evidence-only AI analysis | Snapshot 06/07; `MonitorTests.liveCollectionReturnsRealData` |
| SECURITY AUDIT | 15 read-only checks; evidence + severity + confidence; COULD NOT RUN disclosed; preview (dry run) → authorize → apply → re-check; AI explain; report copy; audit log | Snapshots 08–11; live audit on this Mac: firewall off (MEDIUM), stealth off, 2 pending updates, 4 services on all interfaces, 1 dangling launch item, 10 checks PASS |
| Settings | Keychain key save/remove; model ID + presets + verify (`/v1/models`) + test prompt; reasoning toggle; timeouts; monitor prefs; privacy disclosure & toggles; clear session; permissions guide | Built; verify/ping paths covered by live API behaviour checks |
| Docs | agents.md, CLAUDE.md (replaces GEMINI.md), architecture, threat model, README | this commit |

## Incomplete / not yet verified
- Firewall remediation **apply** path was not executed on this Mac (it would change the real firewall; requires the
  user's admin password). Preview, validation, approval gating and post-check verification logic are tested with mocks.
- No XCUITest-style automated UI tests (Xcode is not installed; XCTest UI testing unavailable). UI is verified with the
  debug snapshot harness instead.
- Settings window not captured by the snapshot harness (opened via SettingsLink only).
- Keyboard-only navigation and VoiceOver labels implemented but not audited with VoiceOver running.

## Known defects / technical debt
- Monitor self-cost: debug build measured ~20% of one core at a 2 s interval (≈60 ms per sample incl. one `ps`
  spawn + SwiftUI table refresh). Next: measure release build; consider sampling restricted processes every 3rd tick.
- PID-reuse window for `process.terminate` (see threat model).
- Ad-hoc signature changes every build → macOS may re-prompt for Keychain access after rebuilding.
- `sandbox-exec` is deprecated by Apple (still functional on macOS 27; fails closed if removed).

## Milestones
1. ✅ Baseline audit & package restructure
2. ✅ Core execution boundary + tests
3. ✅ LLM service (Nemotron-3) + schema + tests
4. ✅ Monitor service + UI
5. ✅ Security audit + remediation flow + audit log
6. ✅ Hardening pass (control-char path bug, protected-dir recursion leak, `open --` removal — all with regression tests)
7. ✅ UI polish pass (rail sizing, title-bar alignment, tile layout, read-only volumes, markdown rendering)
8. ◻ Performance tuning of Monitor (release measurements)
9. ◻ Accessibility audit with VoiceOver; keyboard focus order review
10. ◻ Developer ID signing + notarization (needs an Apple Developer certificate — blocker: none available)

## Test results (latest)
`./test.sh` → `Test run with 148 tests in 42 suites passed` (2026-10-22). `swift build` → 0 warnings.

## Blockers
- Notarized distribution requires a Developer ID certificate.
- Models `nvidia/nemotron-3-super-120b-a12b` and `nvidia/nemotron-nano-3-30b-a3b` are listed but return 404 for this
  account; default is the callable `nvidia/nemotron-3-ultra-550b-a55b`.

## 3.1 additions (verified 2026-10-21)
- 55 registered operations (was 21): diagnostics (hardware w/ serials hidden, battery, sleep blockers, reboots, MDM, boot volume, crash reports, system errors), process tree/open files/graceful app quit, file find/stale/duplicates/SHA-256/cache sizes, Gatekeeper assess, file signature, quarantine origin, firewall rules, admin accounts, connections/DNS/routes/DNS lookup/ping, scoped remediations (SSH perms, DNS flush, Gatekeeper, guest, security updates, Remote Login).
- 23 audit checks (was 15): XProtect age, firewall app rules, system extensions, app signatures, admin accounts, Time Machine, MDM; login window split into auto-login + guest.
- PID-reuse protection (start time pinned at validation, re-checked before signalling). Output filter hides hardware identifiers.
- Runbooks (/runbook), RUN ALL, Tab completion, ⌘O operations palette, transcript & audit Markdown export, CSV export.
- Monitor: alerts (sustained CPU, memory growth, pressure, swap, disk, thermal, battery), power/thermal tile, background monitoring, more process actions, keyboard navigation; ps fallback throttled.
- Security: posture drift since last audit, score history, scheduled audits, notifications, menu bar extra.
- Performance fix: pulsing status-dot animation cost ~28% of a core → discrete blink; Monitor now ~7–9%, idle ~2%.
- SwiftUI Table tried and reverted (framework reentrancy warning on live-sorted rows).
- Tests: 92 passing in 16 suites.

## 3.1 UI revival & code review (verified 2026-10-21)
- Terminal look restored from 2.x: `Last login` line, figlet HACKCODE wordmark, `[  OK  ]` status lines, real
  `user@host ~ %` prompt, `SYS.AI >` / `SYS >` / `WARN >` / `ERR >` prefixes, gutter-style operation blocks with `$ command`,
  bracketed actions (`[ RUN ]`, `[ DENY ]`, `[ EXPLAIN WITH AI ]`), braille spinner while planning/running.
- Matrix rain restored behind the whole window, rebuilt on Core Animation (per-column cached glyph images, compositor-driven
  motion, throttled glyph mutation, paused when hidden, static with Reduce Motion, faster while working).
  Measured in-app cost: SwiftUI Canvas version ~21.6% of a core → Core Animation version ~2.5% (debug build).
  Settings › Appearance: toggle + intensity (default 85%, upgraded once from the older dim default).
- `/` dropdown with every command (13 session commands, 6 runbooks, 55 operations = 74): category tabs, ↑↓ select,
  ↵ run, ⇥ insert, Esc close, argument hint while typing, `[ / ]` button. Operations also run directly
  (`/files.largest path=~/Downloads`). New local commands: /monitor /security /settings /export /history /runall /cancel /explain.
- Code review fixes (each verified): streamed AI text could arrive out of order (now an ordered AsyncStream);
  network timeouts reported "0 s"; report/markdown export depended on the list filter; Model ID saved + audit-logged on every
  keystroke; stale `ps` readings could trigger "sustained CPU" alerts; "Clear session history" kept Monitor alerts;
  `/` dropdown rows were reused stale after filtering (double identity) — fixed.
- Tests: 95 passing in 18 suites; zero compiler warnings; zero NSTableView reentrancy warnings.
- Network scanner and CODEHACK mode were not restored (left out at the user's request).

## 3.2 feature batch (verified 2026-10-21)
- Persistent command history (redacted, owner-only file, toggle + `/history clear`), ⌃R reverse-i-search, ⌃L clear,
  ⌃C interrupt / discard line, RECENT commands first in the `/` dropdown.
- `/watch <op> [k=v] every=N` — re-runs read-only operations (2–300 s, max 360 runs) with changed-line highlighting;
  modifying / approval-gated operations are refused up front.
- Terminal colour themes (green, amber, cyan, mono) via Settings › Appearance or `/theme`; recolours UI and rain.
- `network.port_owner port=N` — which of your processes listens on a TCP port (verified against a real socket in tests).
- 04 STORAGE module: disk-usage explorer (breadcrumbs, streamed sizing, donut breakdown, volume usage, keyboard nav,
  actions staged in SYS.ADMIN for approval; protected folders never entered; per-folder cache).
- tmux-style status line (window tabs, cpu, mem, battery, uptime, alerts, 24-h clock).
- Fuzzy `/` matching with word-start scoring (DP); real startup checks (sandbox availability, restored history).
- Optional notification when an operation running > 10 s finishes while HackCode is in the background.
- Tests: 106 passing in 23 suites; zero warnings.

## 3.3 batch (verified 2026-10-21)
- Pinned processes in MONITOR (by name, max 12): live strip with instances / CPU / memory / sparkline; alerts when a
  pinned process stops or starts (transitions only; tested).
- Aliases: `/alias name <command…>`, `/unalias`, ALIASES tab in the dropdown; single-level expansion (tested).
- Fixed (found by the snapshot harness): Return on an alias recursed forever between submit() and acceptSlash()
  → crash. Exact-command check now includes aliases; accepting a dropdown entry executes directly.
- Fixed (pre-existing): the Monitor's `ps` fallback never worked — `/bin/ps` is setuid and the sandbox refuses to launch
  setuid tools — so other users' processes showed as "pid N" with no data. Now runs with constant args unsandboxed;
  status text no longer counts unmeasured rows as "measured with ps". Regression test added.
- Tests: 111 passing in 25 suites.

## 3.4 batch (verified 2026-10-21)
- ⌘F find in the terminal transcript (match count, older/newer, ⌘G / ⇧⌘G, in-output highlighting, live updates).
- Terminal tabs: ⌘T / ⌘W / ⌘⇧] / ⌘⇧[, independent transcripts, operations and watches per tab; per-tab AI
  conversation memory in LLMService (isolation tested); shared, persisted command history (zsh SHARE_HISTORY style).
- Tests: 112 passing in 26 suites.

## 3.5 batch (verified 2026-10-21)
- Local output pipes: `| grep [-i] [-v] | head | tail | sort [-rn] | uniq | wc -l` on any command, /watch and local tables;
  parsed and applied in-process (never executed); shell-like stages rejected (tested).
- MONITOR › NETWORK pane: per-interface state, addresses (IPv4 first), live/total throughput, bounded in/out history chart,
  staged inspect actions; per-process network usage explicitly not shown (no public API).
- Byte sizes always numeric ("0 KB", never "Zero KB").
- ⌘/ keyboard cheat sheet; ⌘\ hide sidebar; `/report` Markdown system report from local data; `/keys`.
- Crash watcher: new crash / hang / panic reports raise Monitor alerts (+ optional notification) with VIEW REPORT
  (verified on a real report); detection tested; underscore-dated hang names handled.
- Actions staged from other modules now appear as `SYS > ↳ from MONITOR: …`, not as a typed prompt.
- Tests: 119 passing in 28 suites.

## 3.6 batch (verified 2026-10-21, live model)
- MONITOR "WHAT IS THIS? (AI)": process explanation from facts only (name, ~-shortened path, owner, measurements),
  calibrated, never labels malware from name/usage. Live: Finder correctly identified as a known Apple component.
- SECURITY AUDIT "AI BRIEFING": prioritised plan from titles/statuses/severities only — raw evidence never sent (tested).
  Live: correctly prioritised enabling the firewall.
- Tests: 121 passing in 29 suites.

## 3.7 batch (verified 2026-10-21)
- MONITOR process TREE view (LIST/TREE toggle): pstree-style `├─`/`└─`/`│` guides, ▾/▸ collapse per branch, a
  collapsed branch shows `+N` and Σ subtree CPU/RSS (e.g. Claude + 61 helpers as one row). Scope filter applies;
  typing a text filter falls back to the flat list. Arrow keys follow the visible order. Kit: `ProcessTree`
  (cycle-safe, collapsed descendants never re-added) + 3 tests.
- Fixed: LIST rows were reused in TREE (shared pids in one LazyVStack) → stack keyed by mode; duplicate `.id()`
  removed. Fixed: a selected process's detail panel could push the whole window layout past its edges on
  short windows → the panel now scrolls.
- Snapshot `02w-tree` (quick harness, isolated data dir). Tests: 124 passing in 30 suites.
- AUDIT LOG search: category chips with live counts (AI / APPROVALS / EXECUTION / AUDIT / MONITOR / SETTINGS),
  1H/24H/7D/ALL TIME window, multi-term search with `-term` exclusion, SESSION vs ON DISK source (new
  `AuditLogService.history(limit:)` reads the rotated + current JSONL, skipping bad lines), EXPORT CSV of the shown
  rows (RFC 4180 + formula-injection guard), dates shown for non-today events, solid row backing over the rain.
- Settings audit entries now say which keys changed (`changed: terminalTheme`) — names only, never values.
- Kit: `AuditLogFilter`, `HackCodeSettings.changedKeys(from:)` + 5 tests. Snapshot `02x-audit-log-filter`.
  Tests: 129 passing in 32 suites.
- MONITOR › TRENDS: hourly local samples (boot-disk free, swap, memory %, battery health + cycles; 180-day
  retention, `trends.json` 0600, never sent to the model) charted with Swift Charts over 7D/30D/180D, with a
  least-squares disk-full forecast ("full in about N days"), cycles/week and health %/month. Recorder runs from
  launch regardless of the visible module. Kit: `TrendSample`/`TrendLog`/`TrendForecast`/`TrendStore` + 3 tests.
  Snapshot `02y-trends` uses synthetic samples written only into the isolated `HACKCODE_DATA_DIR`.
- Settings › Privacy › Backup & transfer: EXPORT / IMPORT settings (versioned `hackcode-settings` JSON). The API
  key is never in settings; the endpoint is never exported or imported; 256 KB cap; type-checked + clamped;
  aliases re-validated like `/alias`; a confirmation lists every changed key, privacy switches being turned on, and
  skipped aliases. Harness verified a crafted file: attacker endpoint ignored, reserved alias skipped.
  Threat model T17 (import) and T18 (CSV formula injection). Kit: `SettingsTransfer` + 3 tests (135 total).
- SYS.ADMIN banner "since last session" recap (after ≥ 6 h away): time away, disk free change (WARN on > 5 GB
  lost or < 10 % free), battery health/cycle change, new crash/hang/panic reports since then (top apps), and audit
  staleness (WARN when none or > 7 days). Local data only; DISMISS hides it. Verified through the real launch
  path with a seeded 50-hour-old sample in an isolated data dir. Kit: `SessionRecap`,
  `CrashReportWatcher.reports(since:)` + 2 tests (137 total).
- Disk forecast alert: when the last 14 days of samples project the boot disk full within 14 days, MONITOR raises
  a WARNING (CRITICAL under 3 days), sends a notification if enabled, and logs it — at most once a day. Harness:
  20 GB free losing 2 GB/day → "Disk projected full in ~10 days", second check suppressed.
- TREE keyboard: ← collapses / goes to parent, → expands / goes to first child (harness-verified sequence).
- SECURITY AUDIT › HISTORY: posture-score chart (85/60 guides, last-run delta), CHECK × RUN drift matrix (last 20
  runs; current issues then most-flipping checks first; absent/could-not-run/observed distinguished) and a run list
  with per-run changes. Markers: ▼ regression, ▲ only for ISSUE→PASS, • neutral (e.g. PASS→COULD NOT RUN) — also
  used by the "since last audit" banner. Kit: `AuditTimeline`, `PostureChange.isImprovement/marker` + 2 tests.
  Snapshot `02zb-audit-history` from 12 synthetic runs in the isolated data dir.
- SYS.ADMIN `/trends` (text summary: samples, disk free + 7 d / 30 d change, forecast, battery, swap) and `/recap`
  (re-shows the launch recap after DISMISS). Kit: `TrendForecast.textReport` (tested). Snapshot `02zc-trends-cmd`.
- STORAGE LIST/MAP toggle: MAP is a squarified treemap (largest 80 items + one grouped tile), colour by kind
  (folder / app-package / file / protected), opacity by share, hover/selected detail bar, double-click opens a
  folder, right-click actions (all still staged for approval), arrow keys. Kit: `Treemap.squarify` + 2 tests
  (proportional areas, in-bounds, disjoint, full coverage, aspect < 1.8 for even values). Snapshot `02j2-storage-map`.
- MONITOR › NETWORK Wi-Fi card (CoreWLAN, native, read-only; no SSID/BSSID so no Location permission): RSSI with
  4-bar quality, noise/SNR, link rate, channel/band/width, PHY, encryption badge + advice, RSSI history. New audit
  check #24 `wifi-security` (open/WEP → HIGH, WPA → MEDIUM, mixed/OWE → LOW, WPA2/WPA3 → PASS). Kit:
  `WiFiMetrics`/`WiFiStatus`/`WiFiSecurity`/`SignalQuality` + 2 tests. Verified live: −71 dBm FAIR, WPA3 STRONG.
- Open Quickly (⇧⌘O): fuzzy "go to anything" over modules, slash commands, findings, processes, STORAGE folders and
  operations, from in-memory state only. ↑↓/↵/esc. Commands and operations are inserted into the command line, never
  run. Scattered subsequence matches are rejected (gap cost ≤ query length). Kit: `QuickOpen.rank` + test.
  Harness: "windowserver" → ↵ → MONITOR with WindowServer selected; fixed a `KeyEquivalent` label caught in the capture.
- `/report` now includes Wi-Fi (signal, link, channel, encryption), long-term trends and audit history (last 10 runs +
  checks that flipped). Menu bar extra: posture falls back to the last recorded run (relative date), DISK free with a
  "full in ~N d" forecast (amber under 14 d), Wi-Fi signal/encryption (amber when weak). Audit history now loads at
  launch. Menu bar rendered by the harness for the first time (`02ze-menubar`).
- New-listener alerts: while MONITOR samples, every 60 s a sandboxed `lsof -nP -iTCP -sTCP:LISTEN` (current user's
  processes) is compared with what was seen since launch; a new command:port raises WARNING when bound to all
  interfaces (plus notification if enabled) or NOTICE when localhost-only, and is audit-logged. Restarts are not
  re-reported. Kit: `ListenerWatch` + 2 tests. Harness: a 127.0.0.1 socket opened by the debug process →
  "NOTICE New listening port … — HackCode — Localhost only".
- STORAGE › APPS: installed-app inventory (/Applications, /Applications/Utilities, ~/Applications; top level only)
  from Info.plist + the first 4 KB of the executable (thin/fat Mach-O parsed natively; nothing executed):
  UNIVERSAL / APPLE SILICON / INTEL ONLY (needs Rosetta 2) / SCRIPT (#! launcher) / NO EXECUTABLE (broken bundle),
  filters ALL / INTEL ONLY / THIRD-PARTY, right-click Reveal / code signature (staged). Live: 23 apps, 0 Intel-only,
  1 broken bundle (SKLauncher: executable missing). Kit: `AppInventory` + 2 tests. Snapshot `02j3-storage-apps`.
- Matrix rain renders column images in the screen's colour space (was DeviceRGB → Core Animation colour-converted
  every commit; profile now shows 0 conversion frames). Idle CPU on SYS.ADMIN measured 0.9 % (quiet machine) and
  2.5–3.5 % while other apps loaded the Mac (load avg ≈ 7); measure with `top -l` intervals, not `ps` (decaying avg).
- Bundle version 3.1 (4), matching the UI.
- Perf pass (harness `HACKCODE_PERF`, debug build, % of one core): profiled the monitor loop and found two costs —
  `SystemMetrics.volumes()` (purgeable-space key, ~9 ms/tick) and CoreWLAN on the main actor (~7 ms/tick). Volumes are
  now cached 30 s and battery 10 s in `SystemMonitor` (invalidated after any state-changing operation, e.g. Trash);
  Wi-Fi is sampled off the main actor, every tick only while NETWORK is visible, otherwise every 15 s.
  Before → after: MONITOR trends 11.3→4.7 %, network 14.5→6.0 %, tree 16.4→8.1 %, processes 12.6→11.0 %,
  SYS.ADMIN 1.6→0.7 %. Found during this: the dev Mac idle-sleeps for ~10 min stretches at night — the harness
  now reports wall time so such windows are recognisable.
- Process-table rows are cached per (sample time, search, scope, sort key, direction), so re-renders for selection,
  hover or alerts no longer re-filter and re-sort ~600 processes. Tests green; the follow-up perf pass was
  inconclusive (the Mac slept through 3 of 5 windows; the clean windows ran during post-wake load) — re-measure on a
  quiet, awake machine.
- Accessibility: TREE rows now speak level, expanded/collapsed with descendant count, and Σ branch CPU/memory when
  collapsed, and expose Expand/Collapse as an accessibility action (the ▾/▸ button sat inside an element that ignores
  children, so VoiceOver could not reach it). MAP tiles get a default action (select) and "Open folder". Verified by
  build + code review only: SwiftUI does not materialise its lazy-stack accessibility tree for in-process traversal
  (probe reached 5–30 nodes), and external AX inspection would need Accessibility permission for the shell — the
  manual VoiceOver pass remains open.

## Remaining
- Firewall/other privileged remediations not executed on the real Mac (require admin password; mock-tested).
- VoiceOver walkthrough; notifications not captured by the snapshot harness (menu bar extra now is).
- Developer ID signing/notarization (no certificate).

## Next concrete task
Re-measure MONITOR processes with `HACKCODE_PERF` on an awake machine (row cache landed); then a VoiceOver pass over the new panes (TREE, TRENDS, HISTORY, MAP, APPS, Open Quickly).
