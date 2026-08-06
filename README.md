# demo.jbnx.io — AI cost research

Research project: measure the real cost (studio credits + tokens) of standing up a **plain website from scratch** with AI.

| | |
|---|---|
| **Live** | https://demo.jbnx.io |
| **Portal** | https://projects.jbnx.io/#/p/demo |
| **Slug** | `demo` |
| **Subject** | Fictional premier real-estate agent — John Doe |

## Method

1. Claim `demo` → one billable session opens (bill.jbnx.io via portal; 100 credits = 1 hour).
2. Complete one major task.
3. Record token usage → status/close-out with customer-facing `--done` → **release** (stops the clock).
4. Repeat per major task so each shows separately as studio credits.

## Stack

Flat static site (HTML/CSS/JS) → GitHub Pages → Cloudflare DNS (`demo.jbnx.io`).

## Agent loop

```bash
./scripts/agent.sh sign-in
./scripts/agent.sh claim demo "what you'll do"
./scripts/agent.sh boot
# work…
./scripts/agent.sh usage --engine cursor --model <model> --in <n> --out <n>
./scripts/agent.sh status --done "…" --state "…" --next "…"
./scripts/agent.sh release "done"
```
