# Legacy sources (HackCode 2.1)

The pre-3.0 flat Swift sources, build script and notes, archived on 2026-10-21 when HackCode was restructured into a
Swift package. They are **not compiled**. Kept for reference only; safe to delete once 3.0 is accepted.

Replaced because the 2.1 terminal executed model-written shell strings guarded by a denylist (e.g. `find … -delete`
auto-ran as "low risk"), severity was assigned by the model, and the network scanner swept other hosts on the LAN —
all outside the 3.0 security policy (`../agents.md`).
