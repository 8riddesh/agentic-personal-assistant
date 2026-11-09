# Personal Daily Assistant

Single-user Android app (Flutter) + FastAPI backend that plans my day, checks whether a task is realistic before I
commit (Jev via OpenRouter), reminds me at T-60/T-30, asks once whether a task is done at its predicted end, and
produces daily/weekly BI reports — emailed only when I ask.

Built spec-first (SDD): **constitution → plan → module specs → tasks → code → tests**.

## Start here
| Document | What it is |
|---|---|
| [constitution.md](constitution.md) | Non-negotiable rules |
| [plan.md](plan.md) | Global technical architecture, data model, API, flows, CI/CD, release |
| [docs/architecture.drawio](docs/architecture.drawio) | System architecture diagram |
| [docs/data-model.drawio](docs/data-model.drawio) | Database ER diagram |

## Getting started
| Step | Where |
|---|---|
| M0 checklist (accounts, secrets, keystore, first deploy) | [docs/m0-setup.md](docs/m0-setup.md) |
| Backend: run, test, lint | [backend/README.md](backend/README.md) |
| Mobile: one-time Android setup, run, build | [mobile/README.md](mobile/README.md) |

## Module specs

### Backend (`backend/app/modules/`)
| Module | Spec | Milestone |
|---|---|---|
| core | [spec](backend/app/modules/core/spec.md) | M1 |
| auth | [spec](backend/app/modules/auth/spec.md) | M1 |
| crypto | [spec](backend/app/modules/crypto/spec.md) | M1 |
| tasks | [spec](backend/app/modules/tasks/spec.md) | M1 |
| day_cycle | [spec](backend/app/modules/day_cycle/spec.md) | M1 |
| schedule | [spec](backend/app/modules/schedule/spec.md) | M2 |
| ai_gateway | [spec](backend/app/modules/ai_gateway/spec.md) | M2 |
| feasibility | [spec](backend/app/modules/feasibility/spec.md) | M2 |
| predictor | [spec](backend/app/modules/predictor/spec.md) | M3 |
| reports | [spec](backend/app/modules/reports/spec.md) | M4 |
| email | [spec](backend/app/modules/email/spec.md) | M4 |
| assistant | [spec](backend/app/modules/assistant/spec.md) | M5 |

### Mobile (`mobile/lib/features/`)
| Feature | Spec | Milestone |
|---|---|---|
| app_shell | [spec](mobile/lib/features/app_shell/spec.md) | M1 |
| tasks | [spec](mobile/lib/features/tasks/spec.md) | M1 |
| notifications | [spec](mobile/lib/features/notifications/spec.md) | M1 / M3 |
| schedule | [spec](mobile/lib/features/schedule/spec.md) | M2 |
| calendar_connect | [spec](mobile/lib/features/calendar_connect/spec.md) | M2 |
| reports | [spec](mobile/lib/features/reports/spec.md) | M4 |
| chat | [spec](mobile/lib/features/chat/spec.md) | M5 |

## Stack
Flutter (Android) · FastAPI · Python 3.12 · uv · pytest · SQLAlchemy async · Supabase Postgres · Render (free) ·
OpenRouter (Jev + free models) · Groq · seaborn/matplotlib · Brevo · GitHub Actions.
