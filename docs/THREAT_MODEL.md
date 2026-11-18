# HackCode 3.0 — Security Threat Model

## Assets
- The user's system integrity and configuration (files, processes, security settings).
- Secrets: NVIDIA API key; credentials on disk (SSH keys, keychains, cloud configs).
- Privacy: file paths, process inventory, security posture, user requests.
- Audit trail integrity (what was proposed / approved / executed).

## Trust boundaries
1. **Model ↔ app**: everything from NVIDIA is untrusted (could be wrong, manipulated by prompt injection, or adversarial).
2. **Command output / file content ↔ app & model**: untrusted data produced by programs and files.
3. **App ↔ OS**: the execution boundary (`CommandExecutor`) — only validated, approved operations cross it.
4. **App ↔ network**: HTTPS to `integrate.api.nvidia.com` only (host-pinned in settings validation).
5. **User ↔ app**: the user is trusted to approve; the UI must show them the truth.

## Threats and mitigations
| # | Threat | Mitigation | Verified by |
|---|---|---|---|
| T1 | Model returns arbitrary shell (`rm -rf`, `curl | sh`) | No free-form command operation exists; unknown ids rejected; exact-match lookup | `unregisteredOperationsAreRejectedNotExecuted`, `unknownAndCaseVariantIdsRejected` |
| T2 | Argument injection / shell metacharacters | No shell; argv arrays; regex-constrained tokens; `--` before paths; paths absolute | `shellMetacharactersAndInjectionRejectedInTokens`, `hostileFolderNameStaysOneArgument` |
| T3 | Model lowers risk or skips confirmation | Local risk only; model label recorded, ignored | `modelCannotLowerRiskOrSkipConfirmation` |
| T4 | Approval bypass / replay / approval for a different op | `Approval` bound to operation UUID; executor checks; single execution | `elevatedOperationRequiresMatchingApproval`, `runsOnceOnly` |
| T5 | Path traversal, symlink escape, TOCTOU swap after approval | Lexical checks, `realpath`, root containment, denied prefixes, re-validation at execution | `PathPolicyTests`, `pathChangedAfterApprovalIsRejected` |
| T6 | Credential discovery via recursive scans | Denied prefixes (`.ssh`, `.aws`, Keychains, Mail, Messages…) excluded from reads and recursion | `standardPolicyProtectsCredentials`, `recursiveScanSkipsProtectedLocations` |
| T7 | Privilege escalation | No sudo; critical ops denied unless parameterless fixed command via macOS admin prompt (firewall/stealth only) | `privilegedOperationsAreCriticalAndNeedConfirmation` |
| T8 | Killing system / other users' processes | Owner check, protected names, pid ≤ 1 / self denied, re-checked at execution | `terminateDeniedForSystemAndForeignProcesses` |
| T9 | Runaway output / hangs / orphaned children | Byte caps, timeouts, process-group SIGTERM→SIGKILL, cancellation | `ProcessRunnerTests` |
| T10 | Read-only tool modifying system or exfiltrating | Seatbelt profile denies writes and network | `sandboxDeniesFileWrites`, `sandboxDeniesNetwork` |
| T11 | Secret leakage to logs / model / children | Keychain only; `Redactor` on logs and prompts; minimal child env; provider error bodies redacted | `secretsRemoved`, `auditLogRedactsAndRestrictsFile`, `environmentIsScrubbed`, `providerErrorDetailIsRedacted`, `requestShapeAndSecretHandling` |
| T12 | Prompt injection via command output | Output sanitised (control chars), bounded, wrapped in tags with explicit do-not-follow; explanation text is never parsed into operations | `streamingExplanationUsesEvidenceAndDropsReasoning` |
| T13 | Malformed / ambiguous model output | Strict decoder, single-object rule, unknown-field rejection, version check, one repair round | `ProposalSchemaTests`, `malformedOutputGetsOneRepairAttempt` |
| T14 | Key sent to a wrong host | Base URL must be https + exact host | `endpointRestrictedToNVIDIA` |
| T15 | False security conclusions | Deterministic evaluators; COULD NOT RUN never counted as pass; verification re-inspects after failures/timeouts | `SecurityCheckTests`, `failedChecksAreDisclosedNotPassed`, `verificationReinspectsState` |
| T16 | Unbounded memory growth | Bounded transcript, conversation memory, live output, ring buffers, audit log rotation | `memoryFoldsOldTurnsIntoSummary`, `conversationMemoryStaysBounded`, `ringBufferBounded` |
| T17 | Crafted settings file (import) redirects the key, enables data sharing silently, or plants hostile aliases | Envelope format/version check, 256 KB cap, endpoint never exported or imported, type-checked decode + clamp, aliases re-validated (reserved/self-reference/pattern), privacy switches turned on are called out and every change listed before applying; aliases still go through normal validation and approval | `neverImportsEndpointAndRevalidates`, `rejectsForeignOversizedFutureAndMistypedFiles` |
| T18 | Spreadsheet formula injection via exported audit-log CSV | Cells starting with `= + - @` tab/CR are prefixed with `'`; RFC 4180 quoting | `csvEscapesAndGuardsFormulas` |

## Known limitations / residual risk
- **PID reuse:** between approval and `kill`, a pid could be reused. Ownership and protected-name checks are repeated
  at execution, narrowing but not eliminating the window. Only SIGTERM/SIGINT are ever sent.
- **`ps` fallback is unsandboxed:** `/bin/ps` is setuid root and macOS's sandbox refuses to launch setuid binaries, so the
  Monitor's fallback for other users' processes runs `ps -axo pid=,ppid=,uid=,rss=,time=,comm=` with constant arguments
  (no user or model input) outside the sandbox. Regression test: `otherUsersProcessesAreMeasuredWithPS`.
- **Unsandboxed operations:** `logs.process_errors` (`log` refuses sandboxing; read-only tool) and `finder.reveal`
  (`open`, needs LaunchServices). Both are clearly labelled UNSANDBOXED in the UI.
- **`sandbox-exec` is deprecated** by Apple but functional on macOS 27; if removed, sandboxed operations fail closed
  (the runner refuses to start them).
- **The app itself is not App-Sandboxed** (it must read system state and spawn system tools). Defense relies on the
  closed registry, validation, approval, and per-child Seatbelt profiles.
- **Ad-hoc signing:** each rebuild changes the code signature, so macOS may ask again for Keychain access to the key.
- **lsof without root** sees only the current user's sockets; Remote/Screen/File Sharing are inferred from launchd
  service state (medium confidence).
- **Model data exposure:** requests and selected, redacted context go to NVIDIA over HTTPS; there is no E2E encryption
  beyond TLS. Users control the optional process summary and auto-explain in Settings.
