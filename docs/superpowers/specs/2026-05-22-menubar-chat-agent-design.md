# Menubar Chat Agent

Date: 2026-05-22
Status: Approved

## Summary

Add a natural-language chat interface inside the macOS menubar popover so
the user can drive Hydra orchestration with prose ("how busy is high-15?",
"start a Ray orch on the three Linux GPU nodes", "tail the log for the
last task on sff"). The LLM produces a structured **plan** which the
backend executes only after the user clicks Run — no autonomous mutation.

## Motivation

Hydra already exposes `/api/orchs`, `/api/devices/{id}/execute`, and the
GPU/metric endpoints, but the user has to remember API shapes and node
names to wire them up. A chat-style interface lets the user describe
*what* they want and lets the LLM compose the *how* against the current
device cache, while keeping a hard "confirm before mutate" gate.

The existing `cfg.Agent.AI` plumbing (lmstudio / ollama / openai / claude
clients in `cmd/server/ai.go`) means we already have a usable LLM
abstraction — we just need a chat-shaped wrapper and a tool catalog.

## Scope

In scope:

- New backend agent service in `internal/usecase/agent/` plus two HTTP
  endpoints:
  - `POST /api/agent/chat` — submits a user turn, returns the LLM's
    next response (either a clarifying question or a plan).
  - `POST /api/agent/execute` — runs a previously returned plan.
- Action catalog (Go) covering reads (`list_devices`, `list_orchs`,
  `get_metrics`, `get_gpu`, `recent_tasks`), orch ops (`create_orch`,
  `delete_orch`), and shell ops (`execute_command`).
- Multi-turn chat UI in `MenuBarView` with persisted in-memory history
  for the running session (cleared on quit).
- Provider selector in `AISettingsTab` for the *chat* role, defaulting
  to the existing `Agent.AI.Default` if no chat-specific provider is set.
- Plan card rendering with per-action expandable rows and a single
  Run / Cancel button pair.

Out of scope (this iteration):

- Long-running streaming output (execute_command returns final stdout
  only — tail-style streaming is a follow-up).
- Cross-session conversation persistence.
- Multiple concurrent plans / queued actions.
- Voice input.
- Tool-use API (function calling) — we use structured JSON output so the
  same code path works with lmstudio / ollama / cloud providers without
  branching on transport capability.

## Architecture

### Layers

```
┌────────────────────────────────────────────────────────────────┐
│ MenuBarView (Swift)                                            │
│   ChatViewModel — turns[], plan?, isThinking                   │
│   Chat input + history scroll + Plan card                      │
└──────────────────┬─────────────────────────────────────────────┘
                   │ POST /api/agent/chat        POST /api/agent/execute
                   ▼
┌────────────────────────────────────────────────────────────────┐
│ web/handler (Go)                                               │
│   APIAgentChat — validates input, calls AgentUseCase.Chat      │
│   APIAgentExecute — validates plan, calls AgentUseCase.Execute │
└──────────────────┬─────────────────────────────────────────────┘
                   ▼
┌────────────────────────────────────────────────────────────────┐
│ usecase/agent (Go) — new package                               │
│   AgentUseCase.Chat(history, msg) → (reply, *plan, error)      │
│   AgentUseCase.Execute(plan) → []actionResult                  │
│   actionRegistry — table of action types → handlers            │
│   planValidator — sanity-checks device IDs, command shape      │
└──────────────────┬─────────────────────────────────────────────┘
                   ▼
┌────────────────────────────────────────────────────────────────┐
│ ai.Registry — existing AI provider abstraction                 │
│   New `chat` role (falls back to Default)                      │
│   New ChatCompletion(messages, schema) helper                  │
└────────────────────────────────────────────────────────────────┘
```

### LLM contract (structured JSON)

Every LLM reply must parse to:

```json
{
  "type": "ask | plan",
  "message": "Free-text shown to the user.",
  "plan": {
    "intent": "One-sentence summary of what the user wants.",
    "actions": [
      { "type": "list_devices",   "args": {} },
      { "type": "create_orch",    "args": { "name": "...", "head_id": "...", "worker_ids": ["...", "..."] } },
      { "type": "execute_command","args": { "device_id": "...", "command": "...", "timeout_seconds": 30 } }
    ]
  }
}
```

`type=ask` carries only `message` (clarifying question, no plan). `type=plan`
carries `message` + `plan` (intent + actions).

Backend system prompt:

- Provides the action catalog (names, args, semantics).
- Provides a snapshot of current device names + IDs + status (so the LLM
  can resolve "the three Linux GPU nodes" without guessing).
- Requires the response to be a single JSON object matching the schema
  above and nothing else.

If parsing fails, the backend asks the LLM to retry once with the parser
error appended; second failure surfaces as an `ask` with the raw text.

### Action catalog

Each entry has: name, JSON arg shape, validator, executor. Executors call
existing usecases — no new business logic.

| Action | Args | Reads/Writes |
|---|---|---|
| `list_devices` | `{}` | read |
| `list_orchs` | `{}` | read |
| `get_metrics` | `{device_id}` | read |
| `get_gpu` | `{device_id?}` | read |
| `recent_tasks` | `{limit?}` | read |
| `create_orch` | `{name, head_id, worker_ids[], mode?}` | write |
| `delete_orch` | `{orch_id, force?}` | write |
| `execute_command` | `{device_id, command, timeout_seconds?}` | write |

Validator checks every device/orch ID against the current cache before
the executor runs. An action with an unknown ID is rejected with a clear
error in the per-action result.

### Multi-turn state

Chat history lives on the **client** (Swift `ChatViewModel.turns`) and is
sent on every `/api/agent/chat` call. The backend is stateless and only
holds an in-process token-budget guard.

A turn is one of:

- `user`: a string the user typed.
- `assistant_ask`: `{message}` from the LLM.
- `assistant_plan`: `{message, plan}` from the LLM.
- `system_result`: post-execute report — per-action status + brief output.

We cap history at 20 turns sent per request (older turns get dropped
oldest-first); the UI keeps everything for the user to scroll.

### Plan execution

`/api/agent/execute` accepts the *exact* plan JSON returned by `/chat`.
The backend:

1. Re-runs the validator to catch stale plans (e.g., a device referenced
   in the plan disappeared from Tailscale between Chat and Execute).
2. Runs actions sequentially in plan order. Each action is independent —
   the LLM had the device cache at planning time, so write actions
   don't need read results threaded through at execute time.
3. Returns `{results: [{action, status, output?, error?}]}`.

Per-action failures don't abort the rest of the plan — every action gets
a status. The UI renders them grouped under the plan card with green /
red row indicators.

## UI

### Menubar layout

`MenuBarView` (300pt wide currently). Chat goes below the existing GPU
summary, above the action buttons. When the chat has content, the
popover auto-expands to ~420pt wide / variable height.

```
┌──────────────────────────────────────────┐
│ GPU Orch Manager                         │
│ (existing GPU summary + per-node bars)   │
├──────────────────────────────────────────┤
│ Chat                                     │
│ ┌──────────────────────────────────────┐ │
│ │ ↑ scroll: turns history              │ │
│ │ • you: how busy is high-15?          │ │
│ │ • assistant_ask: shows result …      │ │
│ │ • plan card (if any) …               │ │
│ └──────────────────────────────────────┘ │
│ [TextField …………… (Enter to send) ]       │
├──────────────────────────────────────────┤
│ 6/10 online · 0 orchs                    │
│ [Open Dashboard] [Refresh Now] [Quit]    │
└──────────────────────────────────────────┘
```

### Plan card

A `GroupBox` rendered inline with the chat history. Header shows the
intent. Body shows each action with its type as a label and args as
a one-line summary (collapsed; tap to expand). Footer has Run and
Cancel buttons. Run is disabled if the validator found a problem
during the chat response (e.g., unknown device) — the row turns red
with an inline message.

### Settings provider selector

`AISettingsTab` already lists provider blocks (default, head, schedule).
Add a fourth: **Chat agent**. Same fields (provider, endpoint, model,
api key). If left empty, the chat usecase falls back to
`Agent.AI.Default`, matching how the other role overrides work.

## Safety

- **No autonomous mutation.** The backend never executes anything until
  it receives the plan back on `/api/agent/execute`. The user must
  click Run.
- **Plan re-validation on execute.** Catches plans whose device IDs
  disappeared in the window between Chat and Execute (Tailscale
  removed a node, etc.).
- **Command guardrails for `execute_command`.** The system prompt
  instructs the LLM never to propose destructive shell commands (`rm
  -rf`, `dd`, etc.). The validator also blocks an explicit deny-list
  (a small set of obviously dangerous prefixes) — the user can still
  type a destructive command directly via the chat, but the LLM won't
  generate one by accident.
- **Token budget.** Each `/chat` call has a hard ceiling on the LLM
  prompt size and output. On overflow, returns an error to the UI
  asking the user to start a fresh chat.
- **No shell injection from device IDs.** Action executors never
  interpolate IDs into shell strings — they pass through the existing
  usecase signatures which already handle escaping.

## Testing

- Unit tests for `planValidator`: unknown IDs rejected, missing args
  rejected, well-formed plans pass.
- Unit tests for the JSON parser: malformed LLM output handled, retry
  triggered once, second failure surfaces cleanly.
- Unit tests for each action handler: pass through to existing usecases
  with the right args; per-action error captured but doesn't abort.
- Integration test with a stub LLM that returns canned plans, exercising
  the full Chat → Execute round-trip.
- Manual:
  - "how busy is high-15?" → `ask` with metric numbers.
  - "start a Ray orch on the three Linux GPU nodes" → plan with
    `create_orch` action. Click Run → orch appears in dashboard.
  - "delete that orch" (next turn) → plan referencing the orch ID
    we just created.
  - "run `nvidia-smi` on sff" → plan with `execute_command`. Click
    Run → output appears.
  - Stop the chosen LLM provider mid-conversation → graceful error.

## Risks / tradeoffs

- **LLM accuracy.** Local lmstudio with a 20B model may produce
  malformed JSON or wrong device IDs. We catch this with the validator
  and a single retry; the user can also switch to Claude/OpenAI in
  Settings for higher-quality plans. Worst case: user sees an `ask`
  with the LLM's confused message and tries again.
- **Latency.** Local LLM at 192.168.1.19:1234 typically responds in
  3–8 s for a structured output. The UI shows a spinner during the
  in-flight chat call; users with cloud providers see sub-second.
- **History size growth.** 20-turn cap + 8 KB per turn ≈ 160 KB of
  history per request; well within practical limits.
- **Provider misconfiguration.** If the user picks a provider in
  Settings with no API key, `/chat` returns a clear `provider_not_ready`
  error and the chat UI shows an inline link to open Settings.
- **Race between Chat and Execute.** The validator re-check covers
  device drift; if a node disappears between turn and execute, the
  affected action fails individually and the rest of the plan still
  runs.
