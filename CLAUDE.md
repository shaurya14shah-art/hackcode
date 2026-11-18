# CLAUDE.md — HackCode instructions for Claude Code

Read **`agents.md`** first: it is the canonical product, security and engineering policy. This file only adds
Claude Code workflow notes. Then read **`plan.md`** for current status and the next task.

## Orientation
- Swift package: `Package.swift`. Core logic in `Sources/HackCodeKit`, SwiftUI app in `Sources/HackCode`,
  tests in `Tests/HackCodeKitTests`. Pre-3.0 flat sources are archived in `legacy/v2.1/` (not compiled).
- Security boundary files — change with extra care and tests:
  `Execution/ExecutionPolicy.swift`, `Execution/CommandExecutor.swift`, `Execution/OperationRegistry.swift`,
  `Execution/PathPolicy.swift`, `Execution/ProcessRunner.swift`, `LLM/ProposalSchema.swift`.

## Commands
```bash
./test.sh                 # full test suite (Swift Testing via Command Line Tools)
./build.sh                # release HackCode.app
open HackCode.app         # launch
swift build               # quick compile check
```
Xcode is not installed on the development Mac; do not add an .xcodeproj or rely on `xcodebuild`.

## Tool & terminal rules
- Never run commands that change system security settings (firewall, SIP, Gatekeeper, FileVault) on the dev machine
  while testing; use `MockRunner` / canned evidence instead.
- Never print the NVIDIA API key. To exercise the live model in a debug run, pass it via the environment:
  `HACKCODE_DEV_NVIDIA_API_KEY="$(security find-generic-password -s HackCode_NVIDIA_API_KEY -w)"`.
- Live API calls are allowed only for explicit manual verification, never inside `./test.sh`.
- Screen capture is unavailable to the agent shell; use the debug snapshot harness described in `agents.md`.

## Collaboration boundaries
- One writer per file set. Do not edit security-boundary files and their tests in parallel sessions.
- Adding an operation = registry entry + parameter kinds + risk evaluator (if argument-dependent) + tests +
  a row in `docs/THREAT_MODEL.md` if it modifies state.

## Approval & completion
- Ask the user before any change that would weaken a constraint in `agents.md` (new modifying operation, new
  unsandboxed tool, new data sent to the model).
- Done = builds with no warnings, `./test.sh` green, UI verified via snapshots when visible behaviour changed,
  `plan.md` updated with what was verified.
