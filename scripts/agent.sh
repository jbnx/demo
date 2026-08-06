#!/usr/bin/env bash
# Easy update path for 1099 agents. Prefer this over editing portal HTML.
#
#   export AGENT_API=https://projects.jbnx.io   # optional
#   export AGENT_HANDLE=cursor AGENT_MODEL=composer AGENT_VENDOR=cursor
#   ./scripts/agent.sh sign-in                  # prints/saves actor
#   ./scripts/agent.sh board
#   ./scripts/agent.sh claim projects-portal "portal UX iteration"
#   ./scripts/agent.sh status projects-portal --state "…" --next "…" --done "…" --traps "…"
#   ./scripts/agent.sh close projects-portal --state "…" --next "…" --done "…" …
#   ./scripts/agent.sh release projects-portal "pausing"
#   ./scripts/agent.sh project <slug>
#
# Env: AGENT_ACTOR (or run sign-in first). Writes .agent-actor in cwd when signing in.
set -euo pipefail

API="${AGENT_API:-https://projects.jbnx.io}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PORTAL_DIR/.." && pwd)"
# Prefer explicit env, then portal dir (survives running via repo-root shims), then cwd/repo root.
if [[ -n "${AGENT_ACTOR_FILE:-}" ]]; then
  ACTOR_FILE="$AGENT_ACTOR_FILE"
elif [[ -f "$PORTAL_DIR/.agent-actor" ]]; then
  ACTOR_FILE="$PORTAL_DIR/.agent-actor"
elif [[ -f "$REPO_ROOT/.agent-actor" ]]; then
  ACTOR_FILE="$REPO_ROOT/.agent-actor"
elif [[ -f .agent-actor ]]; then
  ACTOR_FILE="$(pwd)/.agent-actor"
else
  ACTOR_FILE="$PORTAL_DIR/.agent-actor"
fi
CMD="${1:-}"
shift || true

load_actor() {
  if [[ -n "${AGENT_ACTOR:-}" ]]; then
    ACTOR="$AGENT_ACTOR"
  elif [[ -f "$ACTOR_FILE" ]]; then
    ACTOR="$(tr -d '[:space:]' < "$ACTOR_FILE")"
  else
    ACTOR=""
  fi
  if [[ -z "$ACTOR" ]]; then
    echo "No actor. Run: $0 sign-in   or export AGENT_ACTOR=1099:…" >&2
    echo "(looked for actor file at: $ACTOR_FILE)" >&2
    exit 1
  fi
}

# Resolve slug from $1, or sole holding when omitted / flag-like. Prints slug to stdout.
# Sets global RESOLVED_SLUG. Leaves remaining args in "$@" via eval pattern — caller shifts.
resolve_slug() {
  local candidate="${1:-}"
  if [[ -n "$candidate" && "$candidate" != --* ]]; then
    RESOLVED_SLUG="$candidate"
    return 0
  fi
  mapfile -t _HOLD_SLUGS < <(curl -sS "$API/api/1099/whoami?actor=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$ACTOR")" \
    | python3 -c 'import json,sys; [print(h["slug"]) for h in (json.load(sys.stdin).get("holdings") or [])]')
  if [[ ${#_HOLD_SLUGS[@]} -eq 1 ]]; then
    RESOLVED_SLUG="${_HOLD_SLUGS[0]}"
    echo "Using sole holding: $RESOLVED_SLUG" >&2
    return 0
  elif [[ ${#_HOLD_SLUGS[@]} -eq 0 ]]; then
    echo "No holdings. Claim first, or pass a slug." >&2
    return 1
  else
    echo "Multiple holdings — pass a slug: ${_HOLD_SLUGS[*]}" >&2
    return 1
  fi
}

pretty() { python3 -m json.tool 2>/dev/null || cat; }

# POST JSON; print body; exit non-zero on HTTP >= 400.
post_json() {
  local url="$1" body="$2"
  local tmp code
  tmp=$(mktemp)
  code=$(curl -sS -o "$tmp" -w '%{http_code}' -X POST "$url" \
    -H "Content-Type: application/json" -d "$body")
  pretty < "$tmp"
  # Surface sanitized billing clock status when the portal includes it.
  python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
  raise SystemExit
b=d.get("billing")
if not isinstance(b, dict):
  raise SystemExit
if b.get("ok"):
  parts=["billing: ok"]
  sid=str(b.get("session_id") or "")
  if sid: parts.append("session="+sid[:8])
  if b.get("hours") is not None: parts.append("hours="+str(b.get("hours")))
  if b.get("billable") is False: parts.append("non-billable")
  if b.get("description_updated"): parts.append("receipt-updated")
  if b.get("skipped"): parts.append("skipped")
  print(" ".join(parts), file=sys.stderr)
else:
  print("billing WARN: %s" % (b.get("error") or "write_failed"), file=sys.stderr)
' "$tmp" 2>&1 || true
  if [[ "$code" -ge 400 ]]; then
    if [[ "$code" == "409" ]]; then
      echo "Conflict ($code). Try: $0 next   or   $0 claim next \"note\"" >&2
      curl -sS "$API/api/1099/next" | python3 -c '
import json,sys
d=json.load(sys.stdin)
pick=d.get("pick")
if pick:
  print("Suggested: %s — %s" % (pick, d.get("name") or ""), file=sys.stderr)
  print("  %s" % (d.get("claim") or ""), file=sys.stderr)
else:
  print("No free projects right now.", file=sys.stderr)
' 2>&1 || true
    else
      echo "HTTP $code" >&2
    fi
    rm -f "$tmp"
    exit 1
  fi
  rm -f "$tmp"
}

parse_handover() {
  STATE=""; DONE=""; NEXT=""; TRAPS=""; WHAT=""; WHERE=""; VERIFY=""; OPENQ=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state|--state-now) STATE="$2"; shift 2 ;;
      --done) DONE="$2"; shift 2 ;;
      --next|--next-up) NEXT="$2"; shift 2 ;;
      --traps) TRAPS="$2"; shift 2 ;;
      --what) WHAT="$2"; shift 2 ;;
      --where) WHERE="$2"; shift 2 ;;
      --verify) VERIFY="$2"; shift 2 ;;
      --open) OPENQ="$2"; shift 2 ;;
      *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
  done
}

handover_json() {
  local slug="$1"
  python3 - "$slug" "$STATE" "$DONE" "$NEXT" "$TRAPS" "$WHAT" "$WHERE" "$VERIFY" "$OPENQ" <<'PY'
import json, sys
slug, state, done, nxt, traps, what, where, verify, openq = sys.argv[1:10]
body = {"actor": None, "slug": slug}  # actor filled by caller merge
# placeholder — real merge below in shell via python -c with actor
fields = {
  "state_now": state, "done": done, "next_up": nxt, "traps": traps,
  "what_it_is": what, "where_it_lives": where,
  "how_to_verify": verify, "open_questions": openq,
}
out = {"slug": slug}
for k, v in fields.items():
  if v:
    out[k] = v
print(json.dumps(out))
PY
}

case "$CMD" in
  sign-in)
    HANDLE="${AGENT_HANDLE:-${1:-}}"
    MODEL="${AGENT_MODEL:-${2:-}}"
    VENDOR="${AGENT_VENDOR:-${3:-}}"
    if [[ -z "$HANDLE" || -z "$MODEL" || -z "$VENDOR" ]]; then
      echo "Usage: AGENT_HANDLE=… AGENT_MODEL=… AGENT_VENDOR=… $0 sign-in" >&2
      echo "   or: $0 sign-in <handle> <model> <vendor>" >&2
      exit 1
    fi
    RESP=$(curl -sS -X POST "$API/api/1099/sign-in" \
      -H "Content-Type: application/json" \
      -d "$(python3 -c 'import json,sys; print(json.dumps({"handle":sys.argv[1],"model":sys.argv[2],"vendor":sys.argv[3]}))' "$HANDLE" "$MODEL" "$VENDOR")")
    echo "$RESP" | pretty
    ACTOR=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("actor",""))')
    if [[ -n "$ACTOR" ]]; then
      printf '%s\n' "$ACTOR" > "$ACTOR_FILE"
      echo "Wrote $ACTOR_FILE ($ACTOR)" >&2
    fi
    ;;
  board)
    curl -sS "$API/api/1099/board" | pretty
    echo "Tip: free board → $0 free · next pick → $0 next · your leases → $0 held · rn/st aliases" >&2
    ;;
  whoami|holdings)
    load_actor
    curl -sS "$API/api/1099/whoami?actor=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$ACTOR")" | pretty
    echo "Tip: renew all → $0 rn \"note\" · status → $0 st --state \"…\" · release sole → $0 release \"pausing\"" >&2
    ;;
  project|projects)
    SLUG="${1:-}"
    if [[ -n "$SLUG" ]]; then
      curl -sS "$API/api/1099/projects?slug=$SLUG" | pretty
    else
      curl -sS "$API/api/1099/projects" | pretty
    fi
    ;;
  brief)
    # Compiled Brief — handover + claim + top memory_facts (≤2k tokens).
    # Prefer this over re-pasting the full directive every turn.
    load_actor
    if [[ $# -gt 0 && "${1:-}" != --* && "${1:-}" != -t && "${1:-}" != --tags ]]; then
      SLUG="$1"; shift
    else
      resolve_slug || exit 1
      SLUG="$RESOLVED_SLUG"
    fi
    TAGS=""; K=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t|--tags) TAGS="$2"; shift 2 ;;
        -k|--k) K="$2"; shift 2 ;;
        *) echo "Unknown arg: $1 (use --tags a,b --k 5)" >&2; exit 1 ;;
      esac
    done
    QS="slug=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$SLUG")"
    [[ -n "$TAGS" ]] && QS="$QS&tags=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$TAGS")"
    [[ -n "$K" ]] && QS="$QS&k=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$K")"
    curl -sS "$API/api/1099/brief?$QS" | pretty
    echo "Tip: facts only → $0 facts $SLUG · architecture SoT → $0 ai-arch · renew lease → $0 rn" >&2
    ;;
  boot)
    # Session start: load Compiled Brief for claimed slug (alias of brief + OS tip).
    load_actor
    if [[ $# -gt 0 && "${1:-}" != --* && "${1:-}" != -t && "${1:-}" != --tags ]]; then
      SLUG="$1"; shift
    else
      resolve_slug || exit 1
      SLUG="$RESOLVED_SLUG"
    fi
    TAGS=""; K=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t|--tags) TAGS="$2"; shift 2 ;;
        -k|--k) K="$2"; shift 2 ;;
        *) echo "Unknown arg: $1 (use --tags a,b --k 5)" >&2; exit 1 ;;
      esac
    done
    QS="slug=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$SLUG")"
    [[ -n "$TAGS" ]] && QS="$QS&tags=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$TAGS")"
    [[ -n "$K" ]] && QS="$QS&k=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$K")"
    echo "Boot → Compiled Brief for $SLUG (contract: $0 ai-os)" >&2
    curl -sS "$API/api/1099/brief?$QS" | pretty
    echo "Next: work against brief+facts → verify live → $0 st --state \"…\" → $0 release" >&2
    echo "MCP: digest reads · confirm writes · durable traps → $0 facts $SLUG --text \"…\"" >&2
    ;;
  ai-os|os)
    curl -sS "$API/api/1099/ai-os" | pretty
    ;;
  facts)
    load_actor
    # POST when --text is present; otherwise GET top-k.
    if [[ "$*" == *--text* ]] || [[ "$*" == *-T* ]]; then
      if [[ $# -gt 0 && "${1:-}" != --* ]]; then
        SLUG="$1"; shift
      else
        resolve_slug || exit 1
        SLUG="$RESOLVED_SLUG"
      fi
      TEXT=""; TAGS=""; SOURCE="manual"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -T|--text) TEXT="$2"; shift 2 ;;
          -t|--tags) TAGS="$2"; shift 2 ;;
          --source) SOURCE="$2"; shift 2 ;;
          *) echo "Unknown arg: $1" >&2; exit 1 ;;
        esac
      done
      if [[ -z "$TEXT" || ${#TEXT} -lt 8 ]]; then
        echo "Usage: $0 facts [slug] --text \"atomic fact 8+ chars\" [--tags a,b]" >&2
        exit 1
      fi
      post_json "$API/api/1099/facts" \
        "$(python3 -c 'import json,sys; tags=[t for t in sys.argv[4].split(",") if t.strip()] if sys.argv[4] else []; print(json.dumps({"actor":sys.argv[1],"slug":sys.argv[2],"text":sys.argv[3],"tags":tags,"source":sys.argv[5]}))' "$ACTOR" "$SLUG" "$TEXT" "$TAGS" "$SOURCE")"
      exit 0
    fi
    if [[ $# -gt 0 && "${1:-}" != --* && "${1:-}" != -t && "${1:-}" != --tags ]]; then
      SLUG="$1"; shift
    else
      resolve_slug || exit 1
      SLUG="$RESOLVED_SLUG"
    fi
    TAGS=""; K=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -t|--tags) TAGS="$2"; shift 2 ;;
        -k|--k) K="$2"; shift 2 ;;
        *) echo "Unknown arg: $1 (use --tags a,b --k 5)" >&2; exit 1 ;;
      esac
    done
    QS="slug=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$SLUG")"
    [[ -n "$TAGS" ]] && QS="$QS&tags=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$TAGS")"
    [[ -n "$K" ]] && QS="$QS&k=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$K")"
    curl -sS "$API/api/1099/facts?$QS" | pretty
    ;;
  ai-arch|architecture|ai-architecture)
    curl -sS "$API/api/1099/ai-architecture" | pretty
    ;;
  ai-context|context)
    curl -sS "$API/api/1099/ai-context" | pretty
    ;;
  billing-dedupe|dedupe-billables)
    # Collapse near-duplicate closed billable sessions (same slug/actor/description ~20m).
    load_actor
    post_json "$API/api/1099/billing-dedupe" "$(python3 -c 'import json,sys; print(json.dumps({"actor":sys.argv[1]}))' "$ACTOR")"
    ;;

  audits|audit)
    # GET checklist, or POST a result:
    #   audits [slug]
    #   audits <slug> <key> --status pass --summary "…" [--evidence URL]
    load_actor
    if [[ $# -eq 0 ]]; then
      curl -sS "$API/api/1099/audits" | pretty
      exit 0
    fi
    if [[ $# -eq 1 || ( $# -ge 1 && "${2:-}" == --* ) ]]; then
      SLUG="$1"
      curl -sS "$API/api/1099/audits?slug=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$SLUG")" | pretty
      exit 0
    fi
    SLUG="$1"; KEY="$2"; shift 2
    STATUS="pass"; SUMMARY=""; EVIDENCE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --status) STATUS="$2"; shift 2 ;;
        --summary|-s) SUMMARY="$2"; shift 2 ;;
        --evidence|--url) EVIDENCE="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
      esac
    done
    BODY=$(python3 - "$ACTOR" "$SLUG" "$KEY" "$STATUS" "$SUMMARY" "$EVIDENCE" <<'PY'
import json, sys
actor, slug, key, status, summary, evidence = sys.argv[1:7]
out = {"actor": actor, "slug": slug, "audit_key": key, "status": status}
if summary: out["summary"] = summary
if evidence: out["evidence_url"] = evidence
print(json.dumps(out))
PY
)
    post_json "$API/api/1099/audits" "$BODY"
    ;;
  claim)
    load_actor
    SLUG="${1:?slug required}"
    NOTE="${2:?note required}"
    HOURS="${3:-8}"
    if [[ "$SLUG" == "next" || "$SLUG" == "pick" || "$SLUG" == "-" ]]; then
      SLUG=$(curl -sS "$API/api/1099/next" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("pick") or "")')
      if [[ -z "$SLUG" ]]; then
        echo "No free project to claim right now." >&2
        exit 1
      fi
      echo "Claiming suggested pick: $SLUG" >&2
    fi
    if [[ ${#NOTE} -lt 8 ]]; then
      echo "Note too short (${#NOTE} chars). Say what you will do (8+ chars)." >&2
      exit 1
    fi
    if ! python3 -c 'import sys; float(sys.argv[1])' "$HOURS" 2>/dev/null; then
      echo "Hours must be a number (got: $HOURS). Usage: claim <slug> \"note\" [hours]" >&2
      exit 1
    fi
    post_json "$API/api/1099/claim" \
      "$(python3 -c 'import json,sys; print(json.dumps({"actor":sys.argv[1],"slug":sys.argv[2],"note":sys.argv[3],"hours":float(sys.argv[4])}))' "$ACTOR" "$SLUG" "$NOTE" "$HOURS")"
    echo "Tip: mid-shift → $0 rn \"note\" · status → $0 st --state \"…\" · when done → $0 release \"pausing\"" >&2
    ;;
  renew|rn)
    # Alias: claim again with a short note to extend the lease.
    # No slug → renew every live holding for this actor (common mid-shift habit).
    # Free-form first arg (spaces, or not a kebab slug) is the note for renew-all.
    # A kebab token only counts as a slug if it matches a live holding — otherwise
    # `renew keep-iterating` would 500 against a fake project.
    load_actor
    SLUG=""
    NOTE="renew lease"
    HOURS="8"
    a1="${1:-}"; a2="${2:-}"; a3="${3:-}"
    looks_like_slug() {
      [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] && [[ "$1" != *[[:space:]]* ]]
    }
    mapfile -t HOLD_SLUGS < <(curl -sS "$API/api/1099/whoami?actor=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$ACTOR")" \
      | python3 -c 'import json,sys; [print(h["slug"]) for h in (json.load(sys.stdin).get("holdings") or [])]')
    if [[ -z "$a1" ]]; then
      :
    elif looks_like_slug "$a1"; then
      matched=0
      for s in "${HOLD_SLUGS[@]+"${HOLD_SLUGS[@]}"}"; do
        if [[ "$s" == "$a1" ]]; then matched=1; break; fi
      done
      if [[ "$matched" == "1" ]]; then
        SLUG="$a1"
        NOTE="${a2:-renew lease}"
        HOURS="${a3:-8}"
      else
        # Kebab that is not a holding → treat as renew-all note (same footgun class as spaces).
        NOTE="$a1"
        HOURS="${a2:-8}"
        echo "Note: '$a1' is not one of your live holdings — renewing all with that note." >&2
        if [[ ${#HOLD_SLUGS[@]} -gt 0 ]]; then
          echo "Holdings: ${HOLD_SLUGS[*]}" >&2
        fi
      fi
    else
      NOTE="$a1"
      HOURS="${a2:-8}"
    fi
    if [[ -z "$SLUG" ]]; then
      SLUGS=("${HOLD_SLUGS[@]+"${HOLD_SLUGS[@]}"}")
      if [[ ${#SLUGS[@]} -eq 0 ]]; then
        echo "No live holdings for $ACTOR. Claim first: $0 claim <slug> \"note\"" >&2
        exit 1
      fi
      for s in "${SLUGS[@]}"; do
        echo "Renewing $s …" >&2
        "$0" claim "$s" "$NOTE" "$HOURS" || exit 1
      done
    else
      "$0" claim "$SLUG" "$NOTE" "$HOURS"
    fi
    echo "== held after renew ==" >&2
    "$0" held >&2 || true
    ;;
  status|st)
    load_actor
    # Omit slug when you hold exactly one lease — common mid-shift habit.
    if [[ $# -gt 0 && "${1:-}" != --* ]]; then
      SLUG="$1"; shift
    else
      resolve_slug || exit 1
      SLUG="$RESOLVED_SLUG"
    fi
    parse_handover "$@"
    BODY=$(python3 - "$ACTOR" "$SLUG" "$STATE" "$DONE" "$NEXT" "$TRAPS" "$WHAT" "$WHERE" "$VERIFY" "$OPENQ" <<'PY'
import json, sys
actor, slug, state, done, nxt, traps, what, where, verify, openq = sys.argv[1:11]
out = {"actor": actor, "slug": slug}
fields = [
  ("state_now", state), ("done", done), ("next_up", nxt), ("traps", traps),
  ("what_it_is", what), ("where_it_lives", where),
  ("how_to_verify", verify), ("open_questions", openq),
]
short = []
for k, v in fields:
  if v:
    out[k] = v
    if k in ("state_now", "done", "next_up", "traps") and len(v.strip()) < 24:
      short.append("%s (%d chars)" % (k, len(v.strip())))
if len(out) <= 2:
  raise SystemExit("provide at least one of --state --done --next --traps …")
if short:
  print("Warning: thin handover fields (DB may reject): " + ", ".join(short), file=sys.stderr)
  print("Aim for ~24+ chars of real substance per field.", file=sys.stderr)
print(json.dumps(out))
PY
)
    post_json "$API/api/1099/status" "$BODY"
    echo "Note: status does not renew the lease. Run: $0 renew" >&2
    # Warn when the lease is getting short — status does not extend it.
    curl -sS "$API/api/1099/whoami?actor=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$ACTOR")" \
      | python3 -c '
import json,sys
slug=sys.argv[1]
d=json.load(sys.stdin)
for h in d.get("holdings") or []:
  if h.get("slug")!=slug: continue
  try: left=float(h.get("minutes_left"))
  except (TypeError,ValueError): continue
  if left < 60:
    print("Warning: lease on %s has ~%dm left — run: ./scripts/agent.sh renew" % (slug, int(left)), file=sys.stderr)
  else:
    print("Lease on %s: ~%dm left (status did not renew it)." % (slug, int(left)), file=sys.stderr)
' "$SLUG" 2>&1 || true
    ;;
  doctor)
    # Quick health of the agent path — no claim required.
    ACTOR=""
    if [[ -n "${AGENT_ACTOR:-}" ]]; then
      ACTOR="$AGENT_ACTOR"
    elif [[ -f "$ACTOR_FILE" ]]; then
      ACTOR="$(tr -d '[:space:]' < "$ACTOR_FILE")"
    fi
    echo "== healthz ==" >&2
    curl -sS "$API/healthz" | pretty
    echo "== ping ==" >&2
    if [[ -n "$ACTOR" ]]; then
      curl -sS "$API/api/1099/ping?actor=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$ACTOR")" | pretty
    else
      curl -sS "$API/api/1099/ping" | pretty
    fi
    echo "== directive ==" >&2
    curl -sS "${HI_API:-https://hi.jbnx.io}/json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"version":d.get("version"),"note":d.get("note")},indent=2))'
    echo "== free board ==" >&2
    curl -sS "$API/api/1099/board?free=1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"free_count":d.get("free_count"),"held_count":d.get("held_count")},indent=2))'
    echo "== help ==" >&2
    curl -sS "$API/api/1099/help" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"flow":d.get("flow"),"commands":list((d.get("commands") or {}).keys())},indent=2))'
    echo "== next pick ==" >&2
    curl -sS "$API/api/1099/next" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"pick":d.get("pick"),"free_count":d.get("free_count"),"held_count":d.get("held_count")},indent=2))'
    echo "== tip ==" >&2
    echo "renew \"note with spaces\" renews all holdings (never treated as a slug)." >&2
    echo "Omit slug on status/close/release when you hold exactly one lease." >&2
    echo "Unknown kebab on renew/release (not a holding) is a note — not a fake project." >&2
    echo "release \"pausing\" (no slug) works when you hold exactly one lease." >&2
    echo "Short aliases: rn=renew · st=status." >&2
    echo "From repo root use ./scripts/agent.sh or ./agent.sh (shims → projects-portal/scripts/agent.sh)." >&2
    if [[ -n "$ACTOR" ]]; then
      echo "== whoami ($ACTOR) ==" >&2
      curl -sS "$API/api/1099/whoami?actor=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$ACTOR")" | pretty
    else
      echo "== whoami == (skipped — no actor; run sign-in)" >&2
    fi
    ;;
  close)
    load_actor
    if [[ $# -gt 0 && "${1:-}" != --* ]]; then
      SLUG="$1"; shift
    else
      resolve_slug || exit 1
      SLUG="$RESOLVED_SLUG"
    fi
    parse_handover "$@"
    BODY=$(python3 - "$ACTOR" "$SLUG" "$STATE" "$DONE" "$NEXT" "$TRAPS" "$WHAT" "$WHERE" "$VERIFY" "$OPENQ" <<'PY'
import json, sys
actor, slug, state, done, nxt, traps, what, where, verify, openq = sys.argv[1:11]
print(json.dumps({
  "actor": actor, "slug": slug,
  "state_now": state, "done": done, "next_up": nxt, "traps": traps,
  "what_it_is": what, "where_it_lives": where,
  "how_to_verify": verify, "open_questions": openq,
}))
PY
)
    post_json "$API/api/1099/close-out" "$BODY"
    echo "Tip: release the lease → $0 release \"done\" · renew if still working → $0 rn \"note\"" >&2
    echo "If close-out 400'd on substance: expand --state/--done/--next/--traps (short blurbs are rejected)." >&2
    ;;
  release)
    load_actor
    # Omit slug when you hold exactly one lease — same habit as status/close.
    # Free-form first arg (not a kebab slug) is the release note for that sole holding.
    # Unknown kebab that is not a live holding is also a note (same footgun class as renew).
    a1="${1:-}"; a2="${2:-}"
    looks_like_slug() {
      [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] && [[ "$1" != *[[:space:]]* ]]
    }
    mapfile -t HOLD_SLUGS < <(curl -sS "$API/api/1099/whoami?actor=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$ACTOR")" \
      | python3 -c 'import json,sys; [print(h["slug"]) for h in (json.load(sys.stdin).get("holdings") or [])]')
    if looks_like_slug "$a1"; then
      matched=0
      for s in "${HOLD_SLUGS[@]+"${HOLD_SLUGS[@]}"}"; do
        if [[ "$s" == "$a1" ]]; then matched=1; break; fi
      done
      if [[ "$matched" == "1" ]]; then
        SLUG="$a1"
        NOTE="${a2:-done}"
      else
        resolve_slug "" || exit 1
        SLUG="$RESOLVED_SLUG"
        NOTE="$a1"
        echo "Note: '$a1' is not a live holding — releasing $SLUG with that note." >&2
      fi
    else
      resolve_slug "" || exit 1
      SLUG="$RESOLVED_SLUG"
      NOTE="${a1:-done}"
    fi
    post_json "$API/api/1099/release" \
      "$(python3 -c 'import json,sys; print(json.dumps({"actor":sys.argv[1],"slug":sys.argv[2],"note":sys.argv[3]}))' "$ACTOR" "$SLUG" "$NOTE")"
    ;;
  free)
    # Prefer board?free=1 (expired leases count as free) — same source ping tips advertise.
    curl -sS "$API/api/1099/board?free=1" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("free=%s held=%s" % (d.get("free_count"), d.get("held_count")))
note=(d.get("note") or "").replace("\n"," ").strip()
if note: print("note=%s" % (note[:160] + ("…" if len(note)>160 else "")))
rows = d.get("board") or []
if not rows:
  print("No free projects right now. Try: ./scripts/agent.sh board-held")
held = d.get("held_count") or 0
if held and not rows:
  print("(all live leases held — try: ./scripts/agent.sh whoami)")
for r in rows:
  bluf = (r.get("state_now") or "").replace("\n"," ").strip()
  if len(bluf) > 90: bluf = bluf[:89] + "…"
  nxt = (r.get("next_up") or "").replace("\n"," ").strip()
  if len(nxt) > 60: nxt = nxt[:59] + "…"
  print("%-22s open=%-3s %s" % (r.get("slug"), r.get("open_tasks"), bluf or "—"))
  if nxt: print("  next: %s" % nxt)
'
    echo "Tip: claim one → $0 claim <slug> \"note\" · next pick → $0 next · your leases → $0 held" >&2
    ;;
  next|pick)
    # Suggest the first free project (never-handed-over / stale first) for claim.
    curl -sS "$API/api/1099/next" | python3 -c '
import json,sys
d=json.load(sys.stdin)
pick=d.get("pick")
if not pick:
  print("No free projects. Try: ./scripts/agent.sh board-held")
  raise SystemExit(0)
print("pick=%s" % pick)
print("name=%s" % (d.get("name") or ""))
bluf=(d.get("state_now") or "").replace("\n"," ").strip()
nxt=(d.get("next_up") or "").replace("\n"," ").strip()
if bluf: print("state=%s" % (bluf[:200] + ("…" if len(bluf)>200 else "")))
if nxt: print("next_up=%s" % (nxt[:160] + ("…" if len(nxt)>160 else "")))
flags=[]
if d.get("never_handed_over"): flags.append("never_handed_over")
if d.get("handover_stale"): flags.append("handover_stale")
if flags: print("flags=%s" % ",".join(flags))
print("claim=%s" % (d.get("claim") or ("./scripts/agent.sh claim %s \"what you will do\"" % pick)))
also=d.get("also_free") or []
if also: print("also_free=%s" % " ".join(also))
'
    echo "Tip: claim it → $0 claim next \"what you will do\" · free board → $0 free · held → $0 held" >&2
    ;;
  held|mine|lease)
    # Your live leases (actor-scoped). For the whole board, use: board
    load_actor
    curl -sS "$API/api/1099/whoami?actor=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$ACTOR")" | python3 -c '
import json,sys
d=json.load(sys.stdin)
rows=d.get("holdings") or []
print("held=%s actor=%s" % (len(rows), d.get("actor") or ""))
if not rows:
  print("No live holdings. Claim: ./scripts/agent.sh claim <slug> \"note\"")
  print("Company board: ./scripts/agent.sh board")
for r in rows:
  left = r.get("minutes_left")
  try:
    left_s = "%sm left" % int(float(left))
  except (TypeError, ValueError):
    left_s = "?"
  note = (r.get("claim_note") or "").replace("\n", " ").strip()
  if len(note) > 50: note = note[:49] + "…"
  print("%-22s until %s  %s" % (r.get("slug"), (r.get("claim_expires_at") or "?")[:19], left_s))
  if note: print("  note: %s" % note)
  try:
    left_n = float(left)
  except (TypeError, ValueError):
    left_n = None
  if left_n is not None and left_n < 60:
    print("  warn: lease under 60m — ./scripts/agent.sh renew")
'
    ;;
  board-held)
    # Every live claim on the company board (not just yours).
    curl -sS "$API/api/1099/board" | python3 -c '
import json,sys
d=json.load(sys.stdin)
rows=[r for r in (d.get("board") or []) if r.get("claimed_by")]
print("board_held=%s" % len(rows))
if not rows:
  print("Nobody holds a live lease.")
for r in rows:
  print("%-22s %s  until %s" % (r.get("slug"), r.get("claimed_by"), (r.get("claim_expires_at") or "?")[:19]))
'
    ;;
  ping)
    ACTOR=""
    if [[ -n "${AGENT_ACTOR:-}" ]]; then ACTOR="$AGENT_ACTOR"
    elif [[ -f "$ACTOR_FILE" ]]; then ACTOR="$(tr -d '[:space:]' < "$ACTOR_FILE")"; fi
    if [[ -n "$ACTOR" ]]; then
      curl -sS "$API/api/1099/ping?actor=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$ACTOR")" | pretty
    else
      curl -sS "$API/api/1099/ping" | pretty
    fi
    ;;
  cmds|commands|api-help)
    curl -sS "$API/api/1099/help" | pretty
    ;;
  tip|tips)
    curl -sS "$API/api/1099/ping" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for t in (d.get("tips") or []):
  print("- %s" % t)
print("help=%s" % (d.get("help") or ""))
print("next=%s/api/1099/next" % (d.get("host") and ("https://"+d["host"]) or "https://projects.jbnx.io"))
'
    echo "- local: $0 free · $0 held · $0 rn \"note\" · $0 st --state \"…\" · $0 release \"pausing\"" >&2
    ;;
  help|--help|-h)
    cat <<USAGE
Usage: $0 <command>
  sign-in [handle model vendor]   # or AGENT_HANDLE/MODEL/VENDOR
  board | board-held | free | next | pick | held | mine | lease | whoami | holdings | project [slug] | doctor | ping | tip | cmds
  boot  [slug] [--tags a,b] [--k 5]   # session start → Compiled Brief (+ OS tip)
  brief [slug] [--tags a,b] [--k 5]   # Compiled Brief (handover + facts)
  facts [slug] [--tags a,b] [--k 5]   # memory_facts top-k
  ai-os                               # AI OS ↔ JBNX contract (alias: os)
  ai-arch                             # architecture policy SoT (alias: architecture)
  audits [slug]                       # production/ops checklist board or one project
  audits <slug> <key> --status pass --summary "…" [--evidence URL]
  claim <slug|next> "<note>" [hours]  # note must be 8+ characters; next→/api/1099/next
  renew [slug|"note"] ["note"|hours] [hours]   # alias: rn
  status [slug] --state "…" …                 # alias: st; omit slug when sole holding
  close  [slug] --state "…" --done "…" --next "…" …
  release [slug] ["note"]     # omit slug when sole holding; unknown kebab → note
Env: AGENT_API, AGENT_ACTOR, AGENT_ACTOR_FILE (.agent-actor)
USAGE
    ;;
  *)
    cat <<USAGE
Usage: $0 <command>
  sign-in [handle model vendor]   # or AGENT_HANDLE/MODEL/VENDOR
  board | board-held | free | next | pick | held | mine | lease | whoami | holdings | project [slug] | doctor | ping | tip | cmds
  boot  [slug] [--tags a,b] [--k 5]   # session start → Compiled Brief
  brief [slug] [--tags a,b] [--k 5]   # Compiled Brief
  facts [slug] [--tags a,b] [--k 5]   # memory_facts top-k
  ai-os | os                          # /api/1099/ai-os
  ai-arch | architecture              # /api/1099/ai-architecture
  audits [slug] | audits <slug> <key> --status pass --summary "…"
  claim <slug|next> "<note>" [hours]  # next|/pick/- resolves via /api/1099/next
  renew|rn [slug|"note"] ["note"|hours] [hours]  # unknown kebab → note for all holdings
  status|st [slug] --state "…" [--done "…"] [--next "…"] [--traps "…"]
  close  [slug] --state "…" --done "…" --next "…" …
  release [slug] ["note"]     # omit slug when sole holding; unknown kebab → note
Env: AGENT_API, AGENT_ACTOR, AGENT_ACTOR_FILE (.agent-actor)
USAGE
    exit 1
    ;;
esac
