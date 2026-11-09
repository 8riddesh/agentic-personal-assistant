# Module spec — `backend/email`

> Status: draft v1 · 2026-11-08 · Governed by `constitution.md` (P2, P5, P11, P12) and `plan.md` (§2.3, §4.1, §5.9,
> §11, §12.1, ADR-008). Milestone: M4.

## 1. Purpose & scope

Serves **C10** (email a report only on explicit request). Provides one operation, `EmailService.send`, which delivers
an HTML message with inline chart images and attachments through a pluggable provider, records the attempt in
`email_log`, and returns an `EmailResult`.

In scope: `EmailMessage` / `EmailResult` DTOs, provider protocol, Brevo HTTP API provider (default), SMTP provider
(Gmail app password, STARTTLS 587), a fake provider for tests, retries, `email_log`.

**Out of scope:** deciding *what* or *when* to send (that is `reports`, triggered only by `POST /reports/{id}/email`),
HTML templating of reports (reports renders HTML with Jinja2), choosing the recipient (reports reads
`app_settings.report_email`), inbound mail, bounce webhooks, scheduling, bulk/marketing mail. Email has **no HTTP
endpoints and no background jobs** (P5).

## 2. Folder layout

```
app/modules/email/
├── spec.md
├── __init__.py          # exports: EmailService, get_email_service, EmailMessage, EmailAttachment, EmailResult,
│                        #   EmailStatus, EmailErrorCode
├── service.py           # EmailService: validate → provider with retries → email_log → EmailResult
├── providers/
│   ├── __init__.py      # EmailProvider Protocol, ProviderReceipt, provider error classes, build_provider(settings)
│   ├── brevo.py         # BrevoProvider (httpx.AsyncClient)
│   ├── smtp.py          # SmtpProvider (aiosmtplib)
│   └── fake.py          # FakeProvider (records messages; scripted failures) — tests and ENV=dev without keys
├── mime.py              # html→text fallback, cid reference scan/rewrite, MIME tree builder for SMTP
├── models.py            # EmailLog ORM (private)
├── repository.py        # EmailLogRepository (private)
└── schemas.py           # DTOs
```

No `api.py` (no endpoints).

## 3. Dependencies

- **Internal:** `core` (`Base`, mixins, `Settings`, `get_settings`, `get_session`, `Clock`, `get_clock`, `get_logger`,
  `DomainValidationError`), `crypto` (`EncryptedText` for `recipient`). Only `reports` may import `email`
  (import-linter contract, core spec §7.8).
- **Third-party:** `httpx` (Brevo), `aiosmtplib` (SMTP), stdlib `email.message` / `email.utils` (MIME), `pydantic`.
- **Dev:** `respx` (mock Brevo), `aiosmtpd` (local SMTP sink for SMTP integration test).
- Name note: inside `app/modules/email/*` use absolute stdlib imports (`from email.message import EmailMessage as
  MimeMessage`) to avoid confusion with this package and its `EmailMessage` DTO.

## 4. Data owned

### `email_log` (one row per `send()` call, final outcome)

| Column | SQL type | Null | Default | Notes |
|---|---|---|---|---|
| id | uuid | no | app `uuid4()` | PK |
| report_id | uuid | yes | — | report being emailed; **no FK constraint** (see Open questions Q1); index `ix_email_log_report_id` |
| provider | varchar(16) | no | — | `brevo` \| `smtp` \| `fake` (CHECK) |
| status | varchar(16) | no | — | `sent` \| `failed` (CHECK) |
| provider_message_id | text | yes | — | Brevo `messageId` / SMTP `Message-ID` header |
| error | text | yes | — | `"<error_code>: <sanitised provider message>"`, ≤ 500 chars, never contains the recipient or body |
| attempts | smallint | no | `1` | `CHECK (attempts BETWEEN 1 AND 5)` |
| recipient 🔒 | text | no | — | `EncryptedText(aad="email_log.recipient")` |
| created_at, updated_at | timestamptz | no | `now()` | |

Index `ix_email_log_created_at`. Retention: kept indefinitely (tiny). Migration: `email: create email_log`.

## 5. Public interface

```python
class EmailService:  # canonical (plan §4.1)
    def __init__(
        self,
        session: AsyncSession,
        provider: EmailProvider,
        settings: Settings,
        clock: Clock,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ) -> None: ...
    async def send(self, msg: EmailMessage) -> EmailResult: ...


def get_email_service(
    session=Depends(get_session),
    settings=Depends(get_settings),
    clock=Depends(get_clock),
    request: Request = ...,
) -> EmailService:
    ...
    # provider = request.app.state.email_provider, built lazily on first use by build_provider(settings);
    # its httpx client is closed via app.state.shutdown_hooks (core spec §7.7)
```

### DTOs (`schemas.py`)

```python
class EmailAttachment(BaseModel):
    filename: str = Field(pattern=r"^[A-Za-z0-9._-]{1,100}$")
    mime: Literal["application/pdf", "image/png", "text/csv"]
    content: bytes


class EmailMessage(BaseModel):
    to: EmailStr
    subject: str = Field(min_length=1, max_length=200)
    html: str = Field(min_length=1)
    inline_images: dict[str, bytes] = {}  # cid -> PNG bytes; key pattern ^[A-Za-z0-9._-]{1,64}$
    attachments: list[EmailAttachment] = []
    text: str | None = None  # extra: plain-text alternative; derived from html if None
    report_id: UUID | None = None  # extra: stored in email_log only


class EmailStatus(StrEnum):
    SENT = "sent"
    FAILED = "failed"


class EmailErrorCode(StrEnum):
    NOT_CONFIGURED = "not_configured"
    AUTH_FAILED = "auth_failed"
    RECIPIENT_REJECTED = "recipient_rejected"
    RATE_LIMITED = "rate_limited"
    QUOTA_EXCEEDED = "quota_exceeded"
    PROVIDER_REJECTED = "provider_rejected"
    PROVIDER_UNAVAILABLE = "provider_unavailable"
    OUTCOME_UNKNOWN = "outcome_unknown"
    TOO_LARGE = "too_large"


class EmailResult(BaseModel):
    status: EmailStatus
    provider: str
    email_log_id: UUID
    attempts: int
    provider_message_id: str | None = None
    error_code: EmailErrorCode | None = None
    sent_at: datetime | None = None  # UTC, when the provider accepted the message
```

`sent` means **accepted by the provider**, not delivered to the inbox.

### Provider protocol (`providers/__init__.py`)

```python
class EmailProvider(Protocol):
    name: str
    configured: bool  # False → send() short-circuits with NOT_CONFIGURED

    async def deliver(self, msg: EmailMessage, *, inline_mode: InlineMode) -> ProviderReceipt: ...
    async def aclose(self) -> None: ...


class ProviderReceipt(BaseModel):
    message_id: str | None


class TransientProviderError(Exception):
    code: EmailErrorCode
    retry_after_s: float | None


class PermanentProviderError(Exception):
    code: EmailErrorCode


class OutcomeUnknownError(Exception): ...  # request may have been accepted; never retried
```

## 6. HTTP endpoints

None. Sending is exposed only through `POST /api/v1/reports/{id}/email` (reports spec), which maps a `failed`
`EmailResult` to 502 `upstream_unavailable` (or 422 for `not_configured` / `too_large`, reports' choice).

## 7. Behaviour & rules

### 7.1 `send(msg)`
1. **Validate** (raise `DomainValidationError`, nothing logged to `email_log` — caller bug):
   - every `cid:` reference found in `html` (regex `src=["']cid:([^"']+)["']`) has a key in `inline_images`;
     unreferenced inline images are allowed but logged at DEBUG;
   - inline images start with the PNG signature `\x89PNG\r\n\x1a\n`;
   - attachment filenames unique and not colliding with `<cid>.png` names;
   - total raw payload (html + images + attachments) ≤ `EMAIL_MAX_TOTAL_BYTES` (default 8 MiB) → else return a
     `failed` result with `TOO_LARGE` and a log row (it is a data-size condition, not a code bug).
2. If `msg.text is None`: derive plain text from html (strip tags with stdlib `html.parser`, collapse whitespace,
   max 20 000 chars).
3. If `not provider.configured` → result `failed`, `NOT_CONFIGURED`, `attempts=1` (no network).
4. **Attempt loop**, `max_attempts = 3` (1 + 2 retries):
   - `ProviderReceipt` → success.
   - `TransientProviderError` → if attempts remain: sleep `min(retry_after_s or 2**(attempt-1) * 1.0, 10) +
     uniform(0, 0.5)` via the injected `sleep`, retry; else fail with its code.
   - `PermanentProviderError` → fail immediately with its code.
   - `OutcomeUnknownError` (timeout after the request body was sent) → fail immediately with `OUTCOME_UNKNOWN`
     (no retry, to avoid duplicate emails; the user can tap "Email this report" again).
   - Overall wall-clock budget 45 s; when exceeded, stop retrying.
5. **Log:** insert one `email_log` row (`recipient=msg.to`, `report_id`, `provider.name`, status, attempts,
   `provider_message_id`, sanitised `error`). Flush (commit by `get_session`).
6. Return `EmailResult(... sent_at=clock.now_utc() if sent)`. `send` never raises for provider failures.

### 7.2 Inline images — `EMAIL_INLINE_MODE`

| Mode | SMTP | Brevo |
|---|---|---|
| `cid` | Native: `multipart/related`, each image `Content-ID: <cid>`, `Content-Disposition: inline` | Each image sent as an attachment whose `name` is `<cid>.png`, html left with `cid:` refs. **Verify at implementation** whether Brevo's `/v3/smtp/email` maps attachment names to `cid:` references (not confirmed by the spec author); enable only after a manual test in Gmail renders the images inline |
| `attachment` (default) | Same as `cid` (SMTP always supports CID natively; the mode is ignored) | Each `<img src="cid:X">` is replaced by a small placeholder block `<p class="chart-ref">Chart <b>X</b> — see attachment X.png</p>`; images sent as regular attachments `X.png`. The report PDF attachment contains all charts, so nothing is lost |

`data:` URIs are deliberately **not** used: Gmail and several clients strip or block them. Rewriting is done in
`mime.rewrite_cid_refs(html, mode)` (pure function, unit-tested).

### 7.3 Brevo provider
- `POST https://api.brevo.com/v3/smtp/email` (base URL configurable `BREVO_BASE_URL` for tests), headers
  `api-key: <BREVO_API_KEY>`, `accept: application/json`, `content-type: application/json`.
- Body:
  ```json
  {"sender": {"email": "<EMAIL_FROM>", "name": "<EMAIL_FROM_NAME>"},
   "to": [{"email": "<msg.to>"}],
   "subject": "Daily report — Sun 8 Nov",
   "htmlContent": "<html>…</html>",
   "textContent": "…",
   "attachment": [{"name": "report.pdf", "content": "<base64 std>"},
                  {"name": "status_donut.png", "content": "<base64 std>"}]}
  ```
  `attachment` omitted when empty. Verify at implementation: field names, allowed extensions (pdf/png expected to be
  allowed), max payload size, and whether `sender.email` must be a verified sender/domain in the Brevo account.
- Shared `httpx.AsyncClient(timeout=httpx.Timeout(connect=5, read=20, write=20, pool=5))`, created lazily.
- Response mapping:

| Outcome | Mapping |
|---|---|
| 201/200 with `{"messageId": "<...>"}` | receipt (message id may be absent → `None`) |
| 400 | `PermanentProviderError(PROVIDER_REJECTED)`; error text = Brevo `code` + `message`, recipient address scrubbed |
| 401 / 403 | `PermanentProviderError(AUTH_FAILED)` |
| 402 | `PermanentProviderError(QUOTA_EXCEEDED)` (free 300/day; verify code) |
| 429 | `TransientProviderError(RATE_LIMITED, retry_after_s from Retry-After)` |
| 5xx | `TransientProviderError(PROVIDER_UNAVAILABLE)` |
| `httpx.ConnectError`, `ConnectTimeout`, `PoolTimeout` | `TransientProviderError(PROVIDER_UNAVAILABLE)` |
| `ReadTimeout`, `WriteTimeout`, `RemoteProtocolError` after send | `OutcomeUnknownError` |

### 7.4 SMTP provider
- `aiosmtplib.send(mime, hostname=SMTP_HOST, port=SMTP_PORT(587), start_tls=True, username=SMTP_USER,
  password=SMTP_PASSWORD, timeout=20)`. Gmail: `smtp.gmail.com:587`, app password (2-Step Verification required on
  the Google account); `From` must equal `SMTP_USER` or a verified alias, so `EMAIL_FROM` defaults to `SMTP_USER`.
- MIME tree (stdlib `email.message.EmailMessage`, policy `SMTP`):
  `multipart/mixed` → [`multipart/related` → [`multipart/alternative` → [text/plain, text/html], image/png (cid)…],
  attachments…]. Headers: `From` (`formataddr((EMAIL_FROM_NAME, EMAIL_FROM))`), `To`, `Subject`, `Date`,
  `Message-ID` (`make_msgid(domain=<EMAIL_FROM domain>)` → returned as receipt id).
- Error mapping: `SMTPAuthenticationError` → `AUTH_FAILED` (permanent); `SMTPRecipientsRefused` →
  `RECIPIENT_REJECTED` (permanent); `SMTPResponseException` 4xx → transient, 5xx → `PROVIDER_REJECTED` permanent;
  `SMTPConnectError`, `SMTPConnectTimeoutError`, `OSError` before DATA → transient; `SMTPServerDisconnected` /
  `SMTPReadTimeoutError` during/after DATA → `OutcomeUnknownError`.
- Render free web services may block outbound SMTP ports — verify at implementation; SMTP is primarily for local
  development or other hosts (plan ADR-008).

### 7.5 Provider selection (`build_provider(settings)`)
- `EMAIL_PROVIDER=brevo`: `configured = bool(BREVO_API_KEY and EMAIL_FROM)`.
- `EMAIL_PROVIDER=smtp`: `configured = bool(SMTP_HOST and SMTP_USER and SMTP_PASSWORD)`.
- `ENV=test`: tests inject `FakeProvider` via `app.dependency_overrides[get_email_service]`.

### 7.6 P5 guarantee
EmailService is invoked only by `ReportService.email`, which is invoked only by `POST /reports/{id}/email` (and the
assistant's proposal, executed by the app calling that same endpoint). Email has no scheduler, no startup hook and
no endpoint; import-linter forbids any module other than `reports` from importing it.

## 8. Configuration

| Var | Default | Notes |
|---|---|---|
| `EMAIL_PROVIDER` | `brevo` | `brevo` \| `smtp` |
| `BREVO_API_KEY` | none | SecretStr |
| `EMAIL_FROM` | none (smtp: `SMTP_USER`) | verified sender |
| `EMAIL_FROM_NAME` *(added)* | `Daily Assistant` | |
| `EMAIL_INLINE_MODE` *(added)* | `attachment` | `attachment` \| `cid` (§7.2) |
| `EMAIL_MAX_TOTAL_BYTES` *(added)* | `8388608` | pre-base64 size |
| `BREVO_BASE_URL` *(added)* | `https://api.brevo.com` | tests only |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD` | none, `587` | STARTTLS only |

Recipient is never configured here — it is `app_settings.report_email`, passed in `EmailMessage.to` by reports.

## 9. Errors & degradation

- Provider down/unconfigured → `EmailResult(status=failed, error_code=...)` + `email_log` row; report generation and
  the rest of the app are unaffected (P10). No automatic re-send later.
- `DomainValidationError` only for malformed messages (missing cid image, non-PNG inline image, duplicate filenames).
- Brevo free quota (300/day) is irrelevant at single-user volume; `QUOTA_EXCEEDED` surfaces if hit.

## 10. Security & privacy notes

- `recipient` encrypted at rest (🔒). `error` is sanitised: recipient address replaced by `<recipient>`, truncated.
- Logs: `email_send` event with `email_log_id`, `provider`, `status`, `attempts`, `error_code`, `latency_ms` — never
  recipient, subject, html, or attachment names.
- API key / SMTP password only in env (P12); `httpx` request logging (`httpx` logger) kept at WARNING so headers are
  never logged.
- Email bodies contain personal report content in plaintext by necessity (sent over TLS to the provider), only on
  explicit user request.

## 11. Testing plan

Fixtures: `png_bytes` (1×1 PNG), `pdf_bytes` (`%PDF-1.4` stub), `message` (html with `cid:status_donut`, one inline
image, `report.pdf` attachment, `to="me@example.com"`), `fake_sleep` (records delays), `brevo_settings`, `respx_brevo`
(respx router on `BREVO_BASE_URL`), `smtp_sink` (`aiosmtpd` controller on localhost, no TLS, `start_tls=False` override
for the test), `fake_clock`.

| Test | Kind |
|---|---|
| `test_send_brevo_success_payload_shape` (headers `api-key`; `to`, `subject`, `htmlContent`, `textContent`, base64 attachments decode to inputs), `test_send_returns_message_id_and_logs_sent` | unit (respx) + integration (log row) |
| `test_inline_mode_attachment_rewrites_cid_refs`, `test_inline_mode_cid_keeps_refs_and_names_attachments_by_cid` | unit |
| `test_brevo_429_retries_with_retry_after_then_succeeds` (fake_sleep sees Retry-After), `test_brevo_5xx_exhausts_retries_failed_3_attempts`, `test_brevo_400_no_retry`, `test_brevo_401_auth_failed`, `test_brevo_read_timeout_outcome_unknown_no_retry`, `test_brevo_connect_error_retried` | unit (respx) |
| `test_not_configured_returns_failed_without_network` (respx asserts no calls) | unit |
| `test_validation_missing_cid_image_raises`, `test_validation_non_png_inline_raises`, `test_too_large_returns_failed` | unit |
| `test_text_fallback_generated_from_html` | unit |
| `test_smtp_mime_structure` (parse built MIME: related/alternative/attachment parts, `Content-ID: <status_donut>`), `test_smtp_send_to_sink` (aiosmtpd receives one message), `test_smtp_auth_error_permanent`, `test_smtp_disconnect_during_data_outcome_unknown` | unit / integration |
| `test_email_log_recipient_encrypted_at_rest` (uses `assert_no_plaintext`) | integration |
| `test_error_text_scrubs_recipient`, `test_logs_contain_no_recipient_or_subject` (caplog) | unit |
| `test_only_reports_imports_email` (covered by `lint-imports` contract) | static |

No test performs real network I/O (constitution §4): respx `assert_all_mocked=True`, SMTP only to the local sink.

## 12. Acceptance criteria

| ID | Given / When / Then | Test |
|---|---|---|
| EMAIL-AC-01 | Given Brevo configured and a message with one inline image and a PDF, when `send`, then one POST to `/v3/smtp/email` with `api-key` header and base64 attachments is made and `EmailResult.status == sent` with the provider message id | `test_send_brevo_success_payload_shape`, `test_send_returns_message_id_and_logs_sent` |
| EMAIL-AC-02 | Given `EMAIL_INLINE_MODE=attachment`, when sending via Brevo, then no `cid:` reference remains in `htmlContent` and each image is attached as `<cid>.png` | `test_inline_mode_attachment_rewrites_cid_refs` |
| EMAIL-AC-03 | Given SMTP, when sending, then the MIME has `multipart/related` with inline PNG parts whose `Content-ID` matches the html refs, plus the PDF attachment | `test_smtp_mime_structure`, `test_smtp_send_to_sink` |
| EMAIL-AC-04 | Given Brevo returns 429 then 201, when `send`, then it retries honouring `Retry-After` and succeeds with `attempts == 2` | `test_brevo_429_retries_with_retry_after_then_succeeds` |
| EMAIL-AC-05 | Given Brevo returns 503 three times, then the result is `failed`, `provider_unavailable`, `attempts == 3`, and one `email_log` row has status `failed` | `test_brevo_5xx_exhausts_retries_failed_3_attempts` |
| EMAIL-AC-06 | Given a 400/401 or a read timeout, then no retry occurs and the matching error code is returned | `test_brevo_400_no_retry`, `test_brevo_401_auth_failed`, `test_brevo_read_timeout_outcome_unknown_no_retry` |
| EMAIL-AC-07 | Given no API key, when `send`, then `failed`/`not_configured` with no network call | `test_not_configured_returns_failed_without_network` |
| EMAIL-AC-08 | Given a sent email, when the `email_log` row is read raw, then `recipient` is an envelope, not the address | `test_email_log_recipient_encrypted_at_rest` |
| EMAIL-AC-09 | Given any send, then logs and `email_log.error` contain no recipient, subject or body | `test_error_text_scrubs_recipient`, `test_logs_contain_no_recipient_or_subject` |
| EMAIL-AC-10 | Given the codebase, when CI runs, then no module other than `reports` imports `email` and email exposes no endpoint or scheduler | `lint-imports`, `test_only_reports_imports_email` |

## 13. Open questions

- **Q1 (plan §5.9 vs §4 / P4):** `email_log.report_id` is marked FK → `report.id`, but `reports → email` in the
  dependency graph; an FK from email's table into reports' table couples the schemas in the reverse direction and
  forces migration ordering. Specified here as a plain indexed `uuid` without FK (same reasoning plan uses for
  `task.local_date`). Confirm.
- **Q2:** Brevo CID inline-image support via `/v3/smtp/email` is unverified; default mode is `attachment` (charts as
  attachments + full PDF). Switch default to `cid` if a manual test confirms it.
- **Q3:** Render free tier may block SMTP egress ports; SMTP adapter then only useful locally (plan already prefers
  Brevo).
- **Q4:** `EmailMessage` allows a single recipient (`to: EmailStr`) — matches single-user design.
