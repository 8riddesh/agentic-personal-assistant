# M0 setup checklist

M0 exit criterion (plan §17): **CI green on the skeleton · `/health` live · debug APK installs on the phone.**
The code, CI workflows, Dockerfile and `render.yaml` are in the repo; the steps below need *your* accounts and
machine. Tick them in order.

## 1. Tools on your machine

- [ ] **uv** (`pip install uv` or the installer), **Git**, **Flutter stable** (includes Dart), **Android Studio**
      (SDK + the bundled JDK that provides `keytool`), optionally **Docker Desktop** to test the image locally.
- [ ] `cd backend && uv sync && uv run pytest` - passes (DB tests skip without `TEST_DATABASE_URL`).
- [ ] `cd mobile` - follow [`mobile/README.md`](../mobile/README.md) "One-time setup" (`flutter create ...`,
      Gradle signing, `INTERNET` permission), then `flutter analyze && flutter test`.

## 2. GitHub

- [ ] `git init`, first commit, create the repo (private is fine; see plan O4 for the Release-download caveat).
- [ ] Commit `backend/uv.lock`, `backend/openapi.json`, `mobile/pubspec.lock` and the generated `mobile/android/`.
- [ ] Push -> `backend-ci` and `mobile-ci` run. Fix anything red before continuing.

## 3. Supabase (database)

- [ ] Create a free project; save the DB password.
- [ ] *Project Settings -> Database -> Connection string -> **Session pooler*** (IPv4, port **5432**). Use this
      one, not the direct host (IPv6-only) and not the transaction pooler (6543).
- [ ] Keep it for `DATABASE_URL` (`postgresql://postgres.<ref>:<pw>@aws-0-<region>.pooler.supabase.com:5432/postgres`;
      the backend rewrites the scheme itself).

## 4. Secrets to generate

```powershell
python -c "import secrets; print(secrets.token_urlsafe(48))"                                  # JWT_SECRET
python -c "import os,base64; print('1:'+base64.b64encode(os.urandom(32)).decode())"           # ENCRYPTION_KEYS
```

- [ ] **Back up `ENCRYPTION_KEYS` in a password manager.** Losing it makes every encrypted column unreadable (P11).
- [ ] `OWNER_PASSWORD_HASH`: generated in M1 with `uv run python -m app.modules.auth.hash_password`. Until then
      any placeholder string works - login does not exist yet - but the variable must be set.
- [ ] `OWNER_EMAIL`: your login email.

## 5. Render (API hosting)

- [ ] *New -> Blueprint* -> pick the repo (reads `render.yaml`; free plan, Docker, `autoDeploy: false`).
- [ ] Fill the `sync: false` variables: `DATABASE_URL`, `OWNER_EMAIL`, `OWNER_PASSWORD_HASH`, `JWT_SECRET`,
      `ENCRYPTION_KEYS` (the AI / email keys can stay empty until M2 / M4).
- [ ] First deploy (the service builds on creation). Check `https://<service>.onrender.com/health` ->
      `{"status":"ok","db":"ok",...}` (the first request after idle can take 30-60 s).
- [ ] Copy the service's **Deploy Hook URL** (Settings).

## 6. GitHub Actions secrets (Settings -> Secrets and variables -> Actions)

| Secret | Value |
|---|---|
| `RENDER_DEPLOY_HOOK_URL` | the Deploy Hook URL from Render |
| `RENDER_SERVICE_URL` | `https://<service>.onrender.com` |
| `API_BASE_URL` | same URL (used by the release APK build) |
| `ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | step 7 |

- [ ] Push to `main` -> `backend-ci` green -> `deploy-backend` triggers Render and waits until `/health` reports
      the new commit.

## 7. Android signing key (plan §14.1)

```powershell
keytool -genkey -v -keystore daily-assistant.jks -keyalg RSA -keysize 2048 -validity 10000 -alias release
[Convert]::ToBase64String([IO.File]::ReadAllBytes("daily-assistant.jks")) | Set-Clipboard   # -> ANDROID_KEYSTORE_B64
```

- [ ] Store the `.jks` **outside the repo** and **back it up** (password manager + cloud drive). Losing it means the
      next version cannot update in place (uninstall/reinstall; server data is unaffected).
- [ ] Add the four `ANDROID_*` secrets; create local `mobile/android/key.properties` (see `mobile/README.md`).

## 8. Phone

- [ ] Enable *Developer options -> USB debugging*; connect the phone.
- [ ] `cd mobile && flutter run --dart-define=API_BASE_URL=https://<service>.onrender.com` (or install the
      `app-debug.apk` artifact from `mobile-ci`). The home screen should read **"Server is up"**.

## Done when

- [ ] CI is green on `main` · [ ] `/health` is live on Render · [ ] the debug APK is installed and shows "Server is up".

Release signing (`v0.x.y` tag -> `release-apk.yml`) is exercised at M6; verify it earlier if you want to
surface keystore problems sooner.
