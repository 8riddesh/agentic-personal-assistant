# Module Spec — `ai_gateway`

> Backend module · Governed by [`constitution.md`](../../../../constitution.md) and [`plan.md`](../../../../plan.md) §9.
> Single entry point for every AI call: Jev decisions and free-model text fallback through the
> **OpenRouter Python SDK** (one key: `OPENROUTER_API_KEY`), and Groq for language/extraction.
> No TypeSafe account or SDK is used.

## 1. Purpose & scope

| Capability | Role |
|---|---|
| C3 feasibility | `decide()` runs Jev questions; `generate()` writes the suggestion |
| C9 reports | `generate()` writes the narrative |
| C11 assistant | `decide()` routes intents; `extract()` fills slots; `generate()` phrases replies |
| P8 / P10 | typed outputs only; fallback chains; `degraded` flag |

Out of scope: which questions to ask and how to combine answers (callers own that); persisting AI results.

## 2. Folder layout

```
ai_gateway/
├── spec.md
├── __init__.py            # exports AIGateway, NoulQ, ScoreQ, ChoiceQ, NoulA, ScoreA, ChoiceA,
│                          #         DecisionResult, TextResult, ExtractResult, Engine
├── service.py             # AIGateway (orchestration, fallback, caps, logging)
├── questions.py           # question + answer models
├── providers/
│   ├── base.py            # DecisionProvider / TextProvider protocols; ProviderError hierarchy
│   ├── openrouter_client.py  # builds the shared OpenRouter SDK client
│   ├── jev.py             # JevProvider       → open_router.alpha.decisions.create
│   ├── openrouter_text.py # OpenRouterTextProvider → open_router.chat.send (:free models)
│   └── groq.py            # GroqTextProvider; GroqDecisionEmulator
├── prompts/
│   ├── registry.py        # Jinja2 env (StrictUndefined); resolves "module/name.vN.j2"
│   └── decision_emulation.v1.j2
├── models.py              # ai_call_log ORM
├── repository.py          # insert log row, count today's calls
└── schemas.py
```
Prompt templates of other modules live in their own `prompts/` folder; callers pass `"feasibility/suggestion.v1.j2"`;
the registry searches `app/modules/<module>/prompts/`.

## 3. Dependencies

- Modules: `core` (Settings, Clock, errors, session).
- Packages: `openrouter` (official OpenRouter Python SDK — verify exact PyPI name at implementation), `groq`,
  `jinja2`, `pydantic`.

## 4. Data owned — `ai_call_log` (no personal text, P11)

| Column | Type | Notes |
|---|---|---|
| id | uuid PK | |
| provider | text | `jev`, `groq`, `openrouter` |
| model | text | |
| purpose | text | caller tag: `feasibility`, `intent`, `extract_task`, `narrative`, … |
| kind | text | `decide`, `generate`, `extract` |
| status | text | `ok`, `error`, `timeout`, `rate_limited`, `cap_reached`, `invalid_output` |
| latency_ms | int | |
| input_tokens, output_tokens | int null | from response usage when present |
| cost_usd | numeric(12,8) null | OpenRouter usage cost (expected 0 under the free allowance) |
| error_code | text null | SDK error class / HTTP status |
| created_at | timestamptz | index `(provider, created_at)` |

Rows older than 90 days are pruned opportunistically (≈1 % of calls).

## 5. Public interface

```python
class NoulQ(BaseModel):
    instructions: str
    criteria: dict[Literal["true", "false"], str] | None = None
class ScoreQ(BaseModel):
    instructions: str
    criteria: list[str]                       # ordered levels, index 0 first, 2..10 items
class ChoiceQ(BaseModel):
    instructions: str
    criteria: dict[str, str | None]           # option -> description, 2..12 options
Question = NoulQ | ScoreQ | ChoiceQ

class NoulA(BaseModel):   type: Literal["noul"];   noul: float            # P(yes), 0..1
class ScoreA(BaseModel):  type: Literal["score"];  score: float; confidence: float | None = None
                          probabilities: dict[int, float] | None = None; legend: dict[int, str] | None = None
class ChoiceA(BaseModel): type: Literal["choice"]; choice: str; confidence: float | None = None
                          probabilities: dict[str, float] | None = None
Answer = Annotated[NoulA | ScoreA | ChoiceA, Field(discriminator="type")]

class Engine(StrEnum): JEV = "jev"; GROQ_FALLBACK = "groq_fallback"; DETERMINISTIC_ONLY = "deterministic_only"

class DecisionResult(BaseModel):
    answers: dict[str, Answer]                # {} when engine == DETERMINISTIC_ONLY
    engine: Engine
    degraded: bool                            # engine != JEV
    latency_ms: int
class TextResult(BaseModel):  text: str; provider: str; degraded: bool; latency_ms: int
class ExtractResult(BaseModel, Generic[T]): data: T | None; provider: str; degraded: bool; latency_ms: int

class AIGateway:
    async def decide(self, purpose: str, state: dict, questions: dict[str, Question]) -> DecisionResult: ...
    async def generate(self, purpose: str, template: str, context: dict, max_tokens: int = 300) -> TextResult: ...
    async def extract(self, purpose: str, schema: type[T], template: str, context: dict) -> ExtractResult[T]: ...
```
Guarantee: the three methods **never raise for provider failures** — they degrade. They raise
`DomainValidationError` only for caller bugs (bad question shape, unknown template, deny-listed keys).

## 6. HTTP endpoints

None (internal). Observability via `ai_call_log` and structured logs.

## 7. Behaviour & rules

### 7.1 OpenRouter SDK client
```python
from openrouter import OpenRouter


def build_openrouter() -> OpenRouter:
    return OpenRouter(
        api_key=settings.OPENROUTER_API_KEY,
        http_referer=settings.APP_PUBLIC_URL,  # optional attribution headers
        x_open_router_title="Personal Daily Assistant",
    )
```
One client created in the FastAPI lifespan and closed on shutdown (the SDK supports `with`; use its close method
in the lifespan). Calls use the SDK's **async variants** (`create_async` / `send_async` — verify names; if the SDK
version only exposes sync methods, run them via `asyncio.to_thread`). SDK-level retries are disabled
(`retries` option) — the gateway owns retry policy (§7.6).

### 7.2 Jev (`JevProvider`)
```python
res = await open_router.alpha.decisions.create_async(
    model=settings.JEV_MODEL,  # "typesafe/jev-1.14"
    state=state,  # dict (JSON object) or str
    questions={
        "achievable_in_window": {
            "type": "noul",
            "instructions": "…",
            "criteria": {"true": "…", "false": "…"},
        },
        "workload_realism": {"type": "score", "instructions": "…", "criteria": ["…", "…", "…"]},
        "recommended_action": {
            "type": "choice",
            "instructions": "…",
            "criteria": {"proceed": "…", "split": "…"},
        },
    },
)
```
Response (`DecisionsResponse`, serialised via `model_dump()`), expected answer shapes per type:
- noul → `{"type":"noul","noul":0.82}`
- score → `{"type":"score","score":2.4,"confidence":0.7,"probabilities":{…},"legend":{…}}`
- choice → `{"type":"choice","choice":"split","confidence":0.6,"probabilities":{…}}`
plus `usage {input_tokens, output_tokens, cost}`. Mapping code converts to `NoulA/ScoreA/ChoiceA`.
Validation: every requested id present with matching type; noul ∈ [0,1]; score ∈ [0, n−1]; choice ∈ options.
Any violation → `invalid_output` → fallback. SDK errors map to statuses:
`TooManyRequestsResponseError`→`rate_limited`; `PaymentRequiredResponseError` (402, allowance exhausted) →
`cap_reached`; 5xx/`ProviderOverloadedResponseError`/`EdgeNetworkTimeoutResponseError`→`error` (retryable);
other 4xx → `error` (not retried).

### 7.3 `decide()` chain
1. Validate: 1..20 questions; ids match `^[a-z][a-z0-9_]{0,40}$`; `len(json.dumps(state)) ≤ 24 000`.
2. **Jev** via OpenRouter (skip if cap reached or key missing).
3. **Groq emulation** (`GroqDecisionEmulator`): one chat completion, `response_format={"type":"json_object"}`,
   `temperature=0`, model `GROQ_MODEL`, template `decision_emulation.v1.j2`; parse into the same answer models,
   clamp nouls/scores, reject unknown choices → `engine=groq_fallback`, `degraded=true`.
4. **deterministic_only**: `answers={}`, `degraded=true`. Callers must handle it.

`decision_emulation.v1.j2` contract:
```
System: You are a careful judge. Answer each question independently using ONLY the STATE.
Return JSON {"answers": {"<id>": {"type":"noul","noul":<0..1 probability of yes>}
  | {"type":"score","score":<number between 0 and last level index>}
  | {"type":"choice","choice":"<one option key>"}}}. No prose.
User: STATE: {{ state_json }}
QUESTIONS:
{% for id, q in questions.items() %}- {{ id }} ({{ q.type }}): {{ q.instructions }}
  {{ q.criteria_text }}
{% endfor %}
```

### 7.4 `generate()` chain
Render template → **Groq** (`GROQ_MODEL`, `temperature=0.4`, `max_tokens`) → **OpenRouter text** via SDK
`open_router.chat.send_async(model=OPENROUTER_TEXT_FALLBACK_MODEL, messages=[…], stream=False, max_tokens=…)`
→ `TextResult(text="", provider="none", degraded=True)`; callers supply their own fixed fallback text.
Post-process: strip, collapse whitespace, truncate at the template's declared `{# max_chars: N #}`.

### 7.5 `extract()` chain
Render template (includes `schema.model_json_schema()`) → Groq `GROQ_FAST_MODEL`, JSON mode, `temperature=0` →
`schema.model_validate_json()`; on `ValidationError` one repair retry including the error text → OpenRouter
`chat.send` with the same prompt (and `response_format` json if the chosen free model supports it) →
`ExtractResult(data=None, degraded=True)`.

### 7.6 Timeouts, retries, caps

| Provider | Timeout | Retries (429 / 5xx / connect) |
|---|---|---|
| Jev (OpenRouter SDK) | 8 s | 2; backoff 0.5 s·2ⁿ + jitter 0–250 ms |
| Groq | 15 s | 2; honour `retry-after` ≤ 5 s, otherwise next link |
| OpenRouter text (SDK) | 20 s | 1 |

Timeouts enforced with `asyncio.timeout` around each SDK call (plus SDK timeout option where available).
Whole gateway call bounded by 25 s → degrade on expiry.
Caps: before a Jev/Groq attempt, count today's (UTC) `ai_call_log` rows for that provider; ≥ cap → log
`cap_reached`, skip. Count cached in-process for 60 s. The OpenRouter per-key daily limit is the outer guard;
`JEV_DAILY_CALL_CAP` is the in-app guard.

### 7.7 Data minimisation
Callers may send: task titles, categories, times, durations, statuses, aggregate stats, chat text typed by the user.
Never: notes, report_email, credentials. Enforced by a recursive deny-list on `state`/`context` keys
(`notes`, `email`, `password`, `token`, `api_key`) → `DomainValidationError`.

### 7.8 Logging
One `ai_call_log` row per provider attempt. Log lines carry purpose, provider, status, latency — never prompt,
state or response text.

## 8. Configuration

| Var | Default |
|---|---|
| `OPENROUTER_API_KEY` | required for Jev + text fallback |
| `JEV_MODEL` | `typesafe/jev-1.14` |
| `JEV_DAILY_CALL_CAP` | 500 |
| `GROQ_API_KEY`, `GROQ_MODEL`, `GROQ_FAST_MODEL` | verify current model list (plan O2) |
| `GROQ_DAILY_CALL_CAP` | 1000 |
| `OPENROUTER_TEXT_FALLBACK_MODEL` | a `:free` model id, e.g. `meta-llama/llama-3-8b-instruct:free` (verify availability) |
| `APP_PUBLIC_URL` | optional, sent as `HTTP-Referer` attribution |

Missing keys disable the corresponding links (warning logged once at startup); the app still runs (P10).

## 9. Errors & degradation

| Situation | Outcome |
|---|---|
| Jev 429/402/5xx/timeout/invalid output/cap | Groq emulation, `engine=groq_fallback`, `degraded=true` |
| Groq also fails | `engine=deterministic_only`, `answers={}` |
| Text providers all fail | `TextResult(text="", degraded=True)` |
| Extraction invalid twice + fallback fails | `ExtractResult(data=None, degraded=True)` |

## 10. Security & privacy

Keys only from env, never logged or returned. TLS only (SDK default). Deny-list (§7.7). No personal text in logs.

## 11. Testing plan (pytest; no network)

The OpenRouter SDK client and Groq client are injected; tests use fakes/`AsyncMock` returning recorded response
objects (fixtures captured once from real calls, stored under `tests/ai_gateway/fixtures/`).

- `test_jev_call_uses_openrouter_sdk_with_model_state_questions`
- `test_decide_jev_success_maps_all_answer_types`
- `test_decide_missing_or_mistyped_answer_falls_back`
- `test_decide_jev_429_then_groq_ok_marks_degraded`
- `test_decide_402_allowance_exhausted_is_cap_reached`
- `test_decide_all_fail_returns_deterministic_only`
- `test_groq_emulation_clamps_and_rejects_unknown_choice`
- `test_generate_groq_fail_openrouter_chat_send_ok`, `test_generate_all_fail_empty_text`
- `test_extract_repair_retry_succeeds`, `test_extract_invalid_twice_returns_none`
- `test_cap_reached_skips_provider_and_logs`
- `test_missing_openrouter_key_skips_jev`
- `test_deny_list_rejects_notes_key`
- `test_one_log_row_per_attempt_without_text`
- `test_sync_sdk_methods_wrapped_in_thread` (only if async variants are unavailable)

## 12. Acceptance criteria

| ID | Given / When / Then | Tests |
|---|---|---|
| AIGW-AC-01 | Given OpenRouter returns Jev answers for all ids, When `decide`, Then `engine=jev`, `degraded=false`, typed answers per id | `test_decide_jev_success_maps_all_answer_types` |
| AIGW-AC-02 | Jev is called only through the OpenRouter SDK (`alpha.decisions`) with the OpenRouter key | `test_jev_call_uses_openrouter_sdk_with_model_state_questions` |
| AIGW-AC-03 | Given Jev fails, When `decide`, Then Groq emulation returns the same shapes with `degraded=true` | `test_decide_jev_429_then_groq_ok_marks_degraded` |
| AIGW-AC-04 | Given every provider fails, Then no exception and `engine=deterministic_only` | `test_decide_all_fail_returns_deterministic_only` |
| AIGW-AC-05 | Given the Jev daily cap (or OpenRouter allowance) is reached, Then Jev is skipped | `test_cap_reached_skips_provider_and_logs`, `test_decide_402_allowance_exhausted_is_cap_reached` |
| AIGW-AC-06 | Each provider attempt writes one `ai_call_log` row with no prompt/response text | `test_one_log_row_per_attempt_without_text` |
| AIGW-AC-07 | A `state` containing `notes` is rejected | `test_deny_list_rejects_notes_key` |
| AIGW-AC-08 | `extract` returns a validated model or `None`, never malformed data | `test_extract_*` |

## 13. Open questions

1. Exact PyPI package name and async method names of the OpenRouter Python SDK (`create_async` / `send_async`) — verify at implementation.
2. Confirm current Groq model ids and the OpenRouter `:free` text model (plan O2).
