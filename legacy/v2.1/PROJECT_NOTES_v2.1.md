# HackCode — macOS Security Intelligence Platform

## Overview
HackCode is a macOS-native SwiftUI application that provides:
1. **System Admin Terminal** — AI-powered command execution with safety validation
2. **Activity Monitor** — Process viewer with AI-powered explanations
3. **Security Audit** — Automated local security posture assessment with LLM analysis
4. **Network Scanner & Topology Map** — Live ARP discovery, ping sweep, service port auditing, and interactive Canvas network graph

## Architecture
- **UI Layer**: `ContentView`, `SecurityDashboardView`, `SecurityTerminalView`, `SecuritySidebarView`, `NetworkScannerView`, `NetworkTopologyView`, `MatrixRainView`
- **Core Logic**: `SecurityEngine`, `SecurityEngineComponents`, `NetworkScanner`, `CorrelationEngine`, `RiskEngine`
- **Command System**: `CommandExecutor` (process runner with quote-aware tokenizer), `CommandValidator` (safety checker)
- **AI Layer**: `LLMService` (NVIDIA API via `meta/llama-3.2-11b-vision-instruct`)
- **Adapters**: `PortScanAdapter`, `DNSAdapter`, `SecretsAdapter`, `MacSecurityAdapter`
- **Models**: `SecurityModels`, `TerminalModels`

## Building & Testing
```bash
cd /Users/shauryashah/AG/HackCode
bash build.sh          # Compile macOS bundle
bash build.sh test     # Run all unit tests
open HackCode.app      # Launch application
```

## API Key Setup
In either the System Admin terminal or Security terminal, type:
```
set-key <YOUR_NVIDIA_API_KEY>
```
The key is stored securely in the macOS Keychain under service name `HackCode_NVIDIA_API_KEY`.

## Available Commands

### System Admin Terminal
- `help` — Show available commands
- `clear` — Clear terminal
- `set-key <KEY>` — Store NVIDIA API key
- `whoami` / `uptime` / `info` — Direct system commands
- `netscan` — Switch to Network Scanner & Topology mode
- `codehack` — Switch to Security Audit mode
- Any text — AI analyzes and suggests safe terminal commands

### Security Terminal & Slash Command Palette (Codehack Mode Only)
In `codehack` mode, typing or pressing `/` reveals the **Interactive Slash Command Palette** with high accessibility:
- Keyboard navigation (`↑`/`↓` navigate, `↵` execute or autocomplete, `ESC` dismiss)
- VoiceOver accessibility labels and hints (`.accessibilityLabel`, `.accessibilityHint`, keyboard traits)
- Live query search filtering across commands, titles, and descriptions
- Category filter pills: `ALL`, `AUDITS`, `ACTIONS`, `SYSTEM`, `AI ADVISOR`
- Distinct visual badges and risk indicators (`SAFE`, `INFO`, `AUDIT`, `MODIFY`)

**Strict Access Guardrail**:
- Typing `/` outside of `codehack` mode is blocked with `[ACCESS DENIED] Codehack mode required. Type 'codehack' to unlock.`
- The `/` quick-action button and auto-suggest palette are hidden until `codehack` mode is enabled.

#### Slash Commands Reference
- `/audit` — Full automated assessment across all system hardening, network, and security modules
- `/audit-firewall` — Audit socketfilterfw state, stealth mode, and inbound block policies
- `/audit-sip` — Audit System Integrity Protection (`csrutil`)
- `/audit-gatekeeper` — Audit Gatekeeper and binary signing enforcement (`spctl`)
- `/audit-filevault` — Audit disk encryption and recovery key escrow (`fdesetup`)
- `/audit-ssh` — Audit Remote Login and SSH daemon authorization
- `/audit-sharing` — Audit Apple Remote Desktop, Screen Sharing, File Sharing
- `/audit-autoupdate` — Audit automatic macOS security and software updates
- `/audit-screenlock` — Audit display sleep lock and grace period timer
- `/audit-secrets` — High-speed local regex scan for exposed API keys and private certificates
- `/audit-ports [HOST]` — Passive local TCP service listener audit
- `/audit-dns [DOMAIN]` — Query DNS record configurations (A, MX, TXT/SPF/DMARC)
- `/audit-network` — Launch local network discovery sweep
- `/status` — View current audit state, score, and active findings count
- `/report` — Generate formatted security posture evaluation report
- `/findings` — Display detailed breakdown of detected vulnerabilities
- `/remediate [N]` — Generate step-by-step remediation plans or apply fix
- `/cancel` — Terminate active audit jobs
- `/advisor <QUERY>` — Query AI Security Advisor with findings context
- `/set-key <KEY>` — Store NVIDIA API key securely in Keychain
- `/whoami`, `/uptime`, `/info`, `/processes`, `/clear`, `/help` — Native terminal utilities

## Security Checks
The audit checks: Firewall, SIP, Gatekeeper, FileVault, SSH, Sharing Services, Auto-Update, Screen Lock, Secrets, Ports, and DNS.

## Design
- Hacker aesthetic: Matrix rain background, cyan/red/green monospaced terminal themes
- Dark mode only, glassmorphic panels
- High accessibility: VoiceOver ARIA-equivalent labels, high contrast borders, keyboard-friendly command palettes

