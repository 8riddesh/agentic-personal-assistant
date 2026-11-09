# Constitution — Personal Daily Assistant

> The non-negotiable rules of this project. Every spec, plan, task and line of code must comply.
> If a change needs to break a rule, the rule is amended here **first**, with a dated entry in the Amendment Log.

## 1. Purpose

A personal assistant (Android app + Python backend) that knows my daily plan, stops me from over-committing,
reminds me before tasks start, learns how long my tasks really take, and reports on my day and week.

## 2. Principles

| # | Principle | What it means in practice |
|---|-----------|---------------------------|
| P1 | **Single user, simple login** | Exactly one user. Login is plain **email + password** (no OAuth, no 2FA, no roles, no sign-up screen). The single account is seeded from backend config. |
| P2 | **Free to run** | Every service used must be free for my usage: Render / Supabase / GitHub Actions free tiers, Groq free tier, OpenRouter free models, and **Jev via OpenRouter under my free daily allowance** (API key with a daily spend limit configured on OpenRouter). No paid plan is ever required. |
| P3 | **Spec-driven** | No code without a spec. Order: `constitution.md` → `plan.md` → module `spec.md` → tasks → code → tests. Code that disagrees with its spec is a bug in one of them; fix the spec first if the spec is wrong. |
| P4 | **Modular** | Each module lives in its own folder with its own `spec.md`. Modules talk to each other only through the public service interface their spec defines — never through another module's tables or internals. |
| P5 | **Respect my attention** | Notifications are few and purposeful: 2 pre-start reminders (T-60, T-30) and **one** completion check per task. No nagging loops. Nothing is emailed unless I explicitly ask. |
| P6 | **Consent for personal data** | Google Calendar is read **only when I tap "use calendar" for a specific day**. No background access, no stored Google refresh tokens. |
| P7 | **Advise, don't block** | AI verdicts (feasibility etc.) are advice. I can always override; overrides are recorded, never prevented. |
| P8 | **Deterministic first, AI second** | Anything computable (time overlaps, free minutes, statistics) is computed in code. Jev makes typed judgments; Groq writes language. AI output is always typed/validated before use. |
| P9 | **Learn from my data** | Every task records start, predicted end, actual end and outcome so the duration predictor and reports improve over time. Data is never silently discarded. |
| P10 | **Graceful degradation** | If an AI provider is down or rate-limited, the app still works: tasks, reminders and reports function without AI; Jev falls back to Groq; AI-dependent output carries a `degraded` flag. |
| P11 | **Encrypted at rest by the middleware** | The FastAPI backend encrypts every personal free-text field (task titles, notes, reasons, chat, calendar event titles, report narratives) **before** it reaches the database, and decrypts on read. The database never sees plaintext personal text. Keys live only in backend env vars. |
| P12 | **Secrets stay server-side** | API keys (Groq, OpenRouter, email) and the encryption key live only in backend environment variables / GitHub Actions secrets. The mobile app holds only the backend URL and its session token (in secure storage). |

## 3. Tooling (mandated)

| Area | Tool |
|------|------|
| Python env & deps | **uv** (`pyproject.toml` + `uv.lock`) |
| Python tests | **pytest** (+ pytest-asyncio, respx) |
| Lint / types | ruff, mypy |
| Mobile | Flutter (stable), `flutter test`, `flutter analyze` |
| CI/CD | **GitHub Actions** |

## 4. Quality Bar

- Backend: typed Python, `ruff` clean, `pytest` coverage ≥ 80% on each module's service layer.
- All external calls (LLM, Jev, email, Google) are mocked in tests; no test hits the network.
- Mobile: `flutter analyze` clean, widget tests for every screen, unit tests for every notification-scheduling rule.
- Every module spec contains acceptance criteria written as Given/When/Then; each criterion maps to at least one test.
- CI must be green before anything is deployed.

## 5. Definition of Done (per task)

1. Spec updated (if behaviour changed).
2. Code + tests written; CI green.
3. Acceptance criteria in the module spec ticked.
4. No paid dependency; no secret in the repo; no plaintext personal text written to the DB.

## 6. Amendment Log

| Date | Change | Reason |
|------|--------|--------|
| 2026-11-08 | Initial version | Project kickoff |
