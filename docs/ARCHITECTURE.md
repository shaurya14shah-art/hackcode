# HackCode 3.0 — Architecture

```
┌──────────────────────────── HackCode (SwiftUI app, @MainActor) ────────────────────────────┐
│ RootView ─ HeaderBar (SystemPulse) ─ NavigationRail ─ SysAdminView │ MonitorView │ SecurityAuditView │ Settings │
│            AppModel (composition root) owns services + SysAdmin/Monitor/SecurityAudit view models          │
└───────────────┬───────────────────────────────┬──────────────────────────────┬──────────────┘
                │                               │                              │
        LLMService (actor)              CommandExecutor (actor)        SystemMonitor (actor)
        HTTPTransport ──HTTPS──► NVIDIA  ExecutionPolicy ◄─ OperationRegistry   ProcessSampler (actor)
        ProposalDecoder (schema v1)      PathPolicy            │                SystemMetrics (Mach/sysctl)
        ConversationMemory (bounded)     ProcessRunner (posix_spawn + Seatbelt) SecurityAuditService (actor)
                                         AuditLogService (actor, JSONL)         SecurityToolRegistry (checks)
```

## Modules (`Sources/HackCodeKit`)
| Area | Files | Responsibility |
|---|---|---|
| Core | `Errors`, `Redactor`, `CredentialStore`, `Configuration` | typed errors, secret redaction & prompt sanitising, Keychain, settings (host-pinned endpoint) |
| Execution | `OperationModels`, `OperationRegistry`, `ExecutionPolicy`, `PathPolicy`, `CommandExecutor`, `ProcessRunner` | the closed operation catalogue, validation & local risk, approval enforcement, sandboxed process launch |
| LLM | `LLMService`, `ProposalSchema`, `ConversationMemory` | NVIDIA chat completions (JSON + SSE), retries/rate limits, strict schema decoding, bounded context |
| Monitor | `SystemMetrics`, `ProcessSampler`, `SystemMonitor` | system metrics, per-process sampling (libproc + ps fallback), ring-buffer history, deterministic observations |
| Security | `FindingModels`, `SecurityToolRegistry`, `SecurityAuditService`, `AuditLogService` | read-only checks with deterministic evaluators, findings, verification, audit log |

## SYS.ADMIN request flow
1. User request → `SysAdminViewModel.ask`.
2. Context gathered locally: macOS version, date, and — only for performance questions and if allowed in Settings —
   top-5 process names/memory. A disclosure line records exactly what was sent.
3. `LLMService.propose` sends system prompt (rules + catalogue), bounded memory, context, request.
4. `ProposalDecoder` requires exactly one JSON object, `schema_version == 1`, ≤ 3 operations, no unknown operation
   fields, integer/string arguments only. One repair round on malformed output.
5. `ValidatedProposal.validate` → `ExecutionPolicy.validate` per operation: exact id lookup, unknown-argument rejection,
   typed/ranged/regex/choice validation, path resolution, local risk assessment, critical-denial.
6. UI shows plan, rejections, exact command/argv, risk basis, sandbox status. Nothing runs automatically.
7. RUN → (if elevated/critical) approval dialog → `ApprovalGate.approve` → `CommandExecutor.execute`:
   single-use check, approval match, **re-validation**, execution, audit log.
8. Output streams through `OutputSink` → `AsyncStream` → main actor.
9. Optional `EXPLAIN WITH AI`: redacted, bounded output wrapped in `<command_output>` with a do-not-follow instruction.
10. Offline: `/ops`, `/run <id> key=value` stage operations without the model (provenance USER, same validation).

## Execution layer details
- **Operation actions:** `.process(executable:sandbox:arguments:)` (fixed absolute executable, argv builder from
  validated args), `.native` (Foundation/Darwin code), `.privilegedFixedCommand` (constant string, macOS admin prompt).
- **ProcessRunner:** `posix_spawn` with `POSIX_SPAWN_SETPGROUP | CLOEXEC_DEFAULT | SETSIGDEF | SETSIGMASK`, stdin
  `/dev/null`, minimal env (`PATH`, `LANG`, `HOME`), poll-based reader with byte cap, timeout watchdog
  (SIGTERM → SIGKILL to the process group), task-cancellation → group kill.
- **Sandbox:** `/usr/bin/sandbox-exec` profiles `readOnlyNoNetwork` (deny file-write* except /dev/null, deny network
  except mDNSResponder socket) and `readOnlyWithNetwork` (for `softwareupdate`). `log show` refuses sandboxing and
  `open -R` needs LaunchServices; both are labelled UNSANDBOXED with the reason.

## Monitor
- `SystemMonitor.collect()` on its actor: CPU ticks delta, VM stats, swap, pressure level, volumes (read-only volumes
  skipped), 64-bit interface counters via `NET_RT_IFLIST2`, processes via `ProcessSampler`.
- Per-process CPU% = Δ(user+system time) / Δwall. Own-user processes via libproc; other users' via one `ps -axo` call with constant arguments every third sample (ps is setuid root, which the sandbox cannot launch, so it runs unsandboxed)
  `ps -axo` call per sample (marked `ps`). Processes unreadable by both are marked restricted.
- History: `RingBuffer` (configurable 10–600 samples); per-process CPU history for ≤120 recently-hot processes.
- Sampling runs only while MONITOR is visible and not paused. Header pulse = system counters every 3 s only.
- AI analysis receives `MonitorObservations.summary` (bounded, deterministic facts + baseline trends).

## Security audit
- 15 checks (firewall, stealth, FileVault, Gatekeeper, SIP, auto-update prefs, pending updates, screen lock,
  login window, Remote Login, Screen Sharing, File Sharing, listening services, launch items, home/SSH permissions).
- Each check = evidence collector (sandboxed tool or native read) + deterministic evaluator → status
  (PASS / ISSUE / OBSERVED / COULD NOT RUN), severity, confidence. The model never decides status.
- Remediation: preview (dry run) → authorization → registered operation (firewall/stealth only) or manual steps +
  System Settings deep link → `verify` re-runs the check → REMEDIATED / UNRESOLVED / unverified.
- Score excludes checks that could not run.

## State & persistence
| Data | Where | Lifetime |
|---|---|---|
| API key | Keychain `HackCode_NVIDIA_API_KEY` (WhenUnlockedThisDeviceOnly) | until removed |
| Settings | UserDefaults `HackCode.settings.v3` (no secrets) | persistent |
| Audit log | `~/Library/Application Support/HackCode/audit-log.jsonl` (0600, rotated at 1 MB) | until cleared |
| Command history | `…/HackCode/command-history.json` (0600; off via Settings › Privacy) | until cleared |
| Audit run history | `…/HackCode/audit-history.json` (0600) | bounded |
| Trend samples (disk free, swap, memory %, battery health/cycles; no names or paths) | `…/HackCode/trends.json` (0600, hourly, 180 days) | until cleared (MONITOR › TRENDS › CLEAR) |
| Transcript, conversation memory, findings | memory only, bounded | session |
