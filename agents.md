# HackCode — Agent Policy (canonical)

This file is the single source of truth for product and engineering rules. Tool-specific files
(`CLAUDE.md`) add workflow notes only and must not contradict this file.

## Product
HackCode is a native macOS (SwiftUI, macOS 14+) system-administration and defensive-security utility with three
integrated modules:
- **SYS.ADMIN** — natural-language requests → NVIDIA Nemotron-3 proposes *registered operations* → HackCode validates
  locally → user approves → controlled execution → streamed output → optional evidence-based AI explanation.
- **MONITOR** — real CPU, memory, swap, pressure, disk, network-interface and per-process metrics with bounded history
  and evidence-only AI analysis.
- **SECURITY AUDIT** — registered read-only local checks, evidence-backed findings, previewed/authorized remediation,
  re-verification and an audit log.

## Non-negotiable constraints
1. **No arbitrary shell.** The model can only name operations in `OperationRegistry`. There is no operation that takes
   free-form command text, and none may be added. New operations need a typed parameter schema, a local risk tier,
   a sandbox profile (or a documented reason for none), timeouts and output limits.
2. **Risk is local.** `ExecutionPolicy` decides risk and confirmation from the operation and its arguments. The model's
   risk label is recorded but never trusted; it can never lower risk or skip approval.
3. **Approval is explicit.** `CommandExecutor` refuses any operation with `requiresConfirmation` unless it receives an
   `Approval` for that exact operation id, created by `ApprovalGate.approve` from a user action. Every operation —
   even informational — runs only after the user presses RUN.
4. **Critical = denied** unless the operation is a parameterless `privilegedFixedCommand` authorised through the macOS
   administrator prompt. Never add sudo, never escalate automatically, never disable SIP/Gatekeeper/firewall.
5. **Paths** go through `PathPolicy` (lexical checks, `realpath`, allowed roots, denied credential locations) at
   proposal time *and* again at execution time.
6. **Untrusted data.** Model output, command output and file content are data. They are sanitised, bounded and
   wrapped before being sent back to the model and never parsed into new operations.
7. **Secrets** live only in the Keychain. Never log, display, or send them to the model. Use `Redactor` for anything
   logged or sent.
8. **Honesty.** No fake metrics, findings, or success states. Unavailable data is shown as unavailable with a reason.
   Never claim sandboxing, encryption or local-only processing that is not implemented and verified.
9. **Scope.** Local machine only. No exploitation, credential access, persistence, stealth, or scanning of other hosts.

## Architecture & conventions
- `Sources/HackCodeKit` — UI-free core (execution boundary, LLM client, monitoring, security). Must stay free of SwiftUI.
- `Sources/HackCode` — SwiftUI app: `App/` (composition root `AppModel`), `DesignSystem/` (all colours, fonts,
  spacing, components), `Features/<Module>/` (view model + views).
- Swift 6 language mode, strict concurrency. Shared mutable state lives in actors; UI state is `@MainActor @Observable`.
- Services are injected via protocols (`ProcessRunning`, `HTTPTransport`, `CredentialStore`, `AuditLogging`,
  `SettingsStore`) so tests never touch the real system or network.
- Typed errors (`HackCodeError`) with plain-language messages. No force-unwraps on external data.
- Use the design tokens in `Theme`; do not introduce ad-hoc colours or fonts.
- See `docs/ARCHITECTURE.md` and `docs/THREAT_MODEL.md`.

## UI conventions
- SYS.ADMIN is a terminal: prompt lines, prefixed output (`SYS.AI >`, `ERR >`), bracketed actions. New local commands
  must be added to `SlashCommandCatalog.sessionCommands` so they appear in the `/` dropdown.
- The Matrix rain is Core Animation-driven (`MatrixRainView`); never reintroduce per-frame SwiftUI drawing or
  `repeatForever` animations without measuring (both have cost 20–30% of a core).

## Testing
- `./test.sh` runs the Swift Testing suite (works with Command Line Tools only). All tests must pass before a change is
  reported as done.
- Security-relevant changes require tests: unknown-operation rejection, argument/path validation, injection strings,
  approval bypass attempts, redaction, timeouts/cancellation.
- Tests must not call the live API, modify system settings, or touch user files outside temporary directories.
  Process tests may only launch harmless binaries (echo, sleep, yes, touch in a temp dir, env, du).

## Build & validation
- `./build.sh` → `HackCode.app` (release, ad-hoc signed). `./build.sh debug` for a debug bundle.
- Visual check without Screen Recording permission: debug builds support
  `HACKCODE_SNAPSHOT_DIR=/tmp/x .build/debug/HackCode` (add `HACKCODE_SNAPSHOT_LIVE_AI=1` and
  `HACKCODE_DEV_NVIDIA_API_KEY` for live AI). It drives real workflows and writes PNGs of the app's own windows.
  Always set `HACKCODE_DATA_DIR=/tmp/y` so audit log, history, trends and settings imports never touch real data
  (synthetic seeding only happens when it is set). `HACKCODE_SNAPSHOT_QUICK=1` stops after the core screens.
- CPU per screen: `HACKCODE_PERF=1` (with the two variables above) logs this process's CPU % over 15 s per screen
  plus wall time and monitor ticks (a wall time far above 15 s means the Mac slept — discard that row).
  `HACKCODE_PERF_HOLD=trends|tree|processes` parks on MONITOR for 25 s after "hold start pid=…" so `sample <pid>`
  can profile it. Debug numbers are for comparison between screens, not absolute.

## Working rules for agents
- Inspect the existing code before changing it; preserve working behaviour unless a documented reason exists.
- Do not describe a feature as complete until its acceptance criteria in `plan.md` are verified, and record the
  evidence (test run, snapshot, live check) in `plan.md`.
- Do not fabricate APIs, model identifiers or provider capabilities — verify against the provider (`/v1/models`).
- Keep `plan.md` current: status, blockers, next task.
