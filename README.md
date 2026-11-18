# HackCode 3.0

Native macOS system-administration and defensive-security terminal: **SYS.ADMIN** (NVIDIA Nemotron-3 plans,
HackCode validates and you approve), **MONITOR** (real-time metrics and processes), **SECURITY AUDIT**
(evidence-backed local hardening checks with verified remediation).

## Requirements
- macOS 14 or later (developed on macOS 27, Apple silicon)
- Xcode Command Line Tools with Swift 6 (`xcode-select --install`)
- An NVIDIA API key from build.nvidia.com for the AI features (monitoring and audits work without one)

## Build & run
```bash
./build.sh            # release build → HackCode.app
open HackCode.app
./test.sh             # run the test suite
```
Then open **Settings (⌘,) › Model**, paste your `nvapi-…` key (stored in the Keychain), press **Verify model** and
**Send test prompt**. Default model: `nvidia/nemotron-3-ultra-550b-a55b`.

## Using it
- **⌘1 SYS.ADMIN** — type a task (“find the largest files in my Downloads folder”). Review the plan and exact command,
  press **RUN** (⌘↩). Changes such as moving files to the Trash or quitting a process need explicit approval.
  `/ops` lists operations; `/run <id> key=value` works without AI.
- **⌘2 MONITOR** — live metrics; click a process for details; Inspect / Signature / Quit stage operations in SYS.ADMIN;
  ask questions about the measurements.
- **⌘3 SECURITY AUDIT** — ⌘⇧R runs 15 read-only checks. Select a finding for evidence, **Preview fix**, **Re-check**.

## Docs
`agents.md` (policy) · `CLAUDE.md` (Claude Code workflow) · `plan.md` (status) · `docs/ARCHITECTURE.md` ·
`docs/THREAT_MODEL.md`

## Limitations
See `plan.md` › Known defects and `docs/THREAT_MODEL.md` › Known limitations.
