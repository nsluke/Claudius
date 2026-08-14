# Design: Claude Code agent activity in Claudius

**Status:** design only — nothing here is built yet.
**Investigated:** 2026-08-13, against Claude Code build `2.1.227` on macOS.

The ask: *"a way to track and know what your agents are doing (or how many are running)."*

Short version: this is feasible, and the session-count half is essentially exact. The
agent-count half is a good approximation with a tradeoff that has no correct setting. Every
signal is undocumented internal state, so the feature needs to degrade gracefully rather
than assume any of it holds.

---

## 1. The one structural fact that shapes everything

**Subagents are not OS processes.** They run in-process inside the parent `claude` PID.
Checking the only live session running a 4-agent workflow, its sole child process was an
unrelated MCP server; thread counts (27–45) don't track agent count either.

So `ps` can count *sessions* and can never count *agents*. These are two different problems
with two different data sources and two very different confidence levels. The UI has to be
honest about that split rather than presenting one blended number.

---

## 2. Data sources, ranked

| Signal | Path | What it gives | Confidence |
|---|---|---|---|
| **Live session roster** | `~/.claude/sessions/<pid>.json` ∩ `ps -p <pid>` | Exact set of running sessions | **Exact** |
| Session metadata | same files | `sessionId`, `cwd`, `startedAt`, `version`, `entrypoint`, derived `name` | Exact |
| Corroborating liveness | `/tmp/cc-socks/<pid>.sock` | Third independent check | Exact |
| **Workflow agent lifecycle** | `…/subagents/workflows/wf_<id>/journal.jsonl` | `started` / `result` records | **Leaky — see §3** |
| Agent identity | sibling `agent-<id>.meta.json` | `agentType`, `description`, `spawnDepth` | Exact when present |
| Agent freshness | mtime of `agent-<id>.jsonl` | The gate that makes lifecycle usable | Heuristic |
| Session label | `custom-title` / `ai-title` / `last-prompt` records | Human-readable name, no conversation content | Good |
| "What is it doing" | `~/.claude/tasks/<sessionId>/<taskId>.json` → `activeForm` | Present-tense activity string | **Unverified — see §5** |
| Busy vs idle | `%CPU` from `ps` | 6.7–13.5% busy vs 0.1–0.7% idle | Heuristic, confounded |

Dead ends, already ruled out: `~/.claude/session-env/` is 11 directories, all empty, keyed by
sessionId including long-dead ones. There are no PID files, no FIFOs, and the only `.lock`
files are zero-byte markers in the tasks directory.

The session files matched live PIDs 1:1 with zero stale entries, which is consistent with
cleanup-on-exit — but a session exiting was never actually observed, so **validate every file
against `ps` rather than trusting its existence.** Guard against PID reuse by comparing the
epoch `startedAt` against `ps -o lstart=`, *not* the `procStart` string: the two are rendered
in different timezones (a 7-hour offset for the same instant).

---

## 3. Why the agent count carries a tilde

Workflow-spawned agents write explicit `{"type":"started"}` / `{"type":"result"}` records. A
`started` with no `result` is the closest thing to an in-flight marker that exists.

It leaks badly. `result` is only written on **clean completion** — crashes, rate-limit
failures, and cancellations orphan the `started` forever. In one historical workflow, **42 of
62 agents had a dangling `started`, and 38 of those transcripts contain an API error record.**
Taken at face value, the marker reports long-dead agents as running.

Gating on agent-transcript mtime fixes that, and introduces the opposite error. In one probe
run the gate reported 3 in-flight agents where the journal showed 4 started / 0 result — the
fourth was alive but had been quiet longer than the 2-minute threshold. Tighten the gate and
you hide live-but-thinking agents; loosen it and you resurrect dead ones. **There is no
threshold that is right.** Hence `~13 agents`, never `13 agents`.

Two further gaps: plain `Agent`-tool subagents (non-workflow) have **no journal at all** — their
only signal is transcript mtime, or pairing `meta.json`'s `toolUseId` against an unresolved
`tool_use` in the parent transcript. And background agents are effectively unobserved: exactly
one `run_in_background` invocation exists in this machine's entire history.

---

## 4. Proposed implementation

### Data layer — `AgentActivityService`

A single composite probe, mirroring the one already validated:

1. Read `~/.claude/sessions/*.json`; keep entries whose PID is alive **and** whose `startedAt`
   matches `ps` (PID-reuse guard).
2. For each live session, glob its `subagents/workflows/*/journal.jsonl`, count
   `started` minus `result` by `agentId`.
3. Gate each candidate on `agent-<id>.jsonl` mtime being fresh.
4. Read `~/.claude/tasks/<sessionId>/*.json` for `activeForm` where status is `in_progress`.
5. Read `%CPU` per PID from one `ps` call for the busy/idle dot.

**Cost:** the full probe measured **28 ms**, so a 2–3 second poll is comfortable. At scale
(hundreds of workflows) the journal step reads whole files — add an mtime skip-cache and tail
reads before that becomes a problem. This should be a **separate timer from the usage sync**,
which stays at 5 minutes; agent state is only interesting at human-reaction speed and only
while a window is actually open.

### UI

**Menu dropdown** — one new section above the divider:

```
Claude Code · 6 sessions · ~13 agents
```

The session count is stated flatly. The agent count carries the tilde, always.

**Dashboard — a new "Agents" section:**

```
● Claudius        ~/Documents/GitHub/Claudius    3 agents   12% cpu
● ProxyBuyer      ~/ProxyBuyer                   —           0% cpu
○ tronbyt-store   ~/tronbyt-store                —          idle 4m
```

One row per live session: derived `name`, abbreviated `cwd`, in-flight agent count, and a
busy/idle dot from CPU% plus transcript mtime. Expanding a row lists agents by `agentType` and
`description` from `meta.json`.

The dashboard window is currently a fixed 340pt wide, which is too narrow for this. Either
widen it or make Agents a second tab.

**Out of scope for v1:** no conversation content, no transcript text, no per-agent progress
bars, no cross-machine aggregation.

### Version gating

Everything above is internal state of build `2.1.227`, and the layout has already changed once
(subagents moved out of inline `isSidechain` records into their own files). Read the `version`
field from the session file and degrade to **session count only** — which is the exact,
robust signal — when it's a version we haven't validated against.

---

## 5. Before building, verify these three

1. **`activeForm` was never caught live.** No task was in `in_progress` on disk at any point
   during the investigation. The status value provably exists (50 `TaskUpdate` calls used it),
   but it was never observed mid-flight. If it's only written at terminal transitions, the
   "what is it doing" column has no data source and that part of the design collapses. **Check
   this first** — it's the cheapest test and it gates a whole column.
2. **TCC / sandbox access.** All of this was probed from a terminal process. Claudius is
   non-sandboxed today (`com.apple.security.app-sandbox = false`), so it should be fine — but
   several `~/.claude` subdirectories are `0700` and `/tmp/cc-socks` is `0700 luke:wheel`.
   Confirm from inside the app bundle before building UI on it. This would invalidate the
   approach entirely for a future sandboxed/App Store build.
3. **Session-file cleanup semantics.** Never observed a session exiting. The `ps` validation
   makes this safe regardless, but knowing whether files are swept on exit, on crash, or lazily
   at startup would tell us whether the roster can ever go stale in the other direction.

## 6. The unexplored lead

`messagingSocketPath` points at `/tmp/cc-socks/<pid>.sock`, and the session file carries a
`peerProtocol: 1` field — which hints at a versioned request/response contract. If that socket
exposes a structured status API, it would be strictly better than every file-scraping signal
above: real in-flight state instead of inference from mtimes.

It was deliberately **not** probed. Connecting isn't read-only in the safe sense — it could
deliver a message into a live session. Worth investigating, but only deliberately and with a
throwaway session, never against a session doing real work.

## 7. Effort

| Piece | Est. |
|---|---|
| `AgentActivityService` + probe + PID-reuse guard | 4h |
| Menu dropdown line | 1h |
| Dashboard Agents section (incl. widening/tabbing the window) | 4h |
| Version gating + graceful degradation | 2h |
| Tests against fixture `~/.claude` trees | 3h |

**~2 days**, and it splits cleanly: the menu-dropdown line alone is about a third of the work
and delivers most of the value. Ship that first.
