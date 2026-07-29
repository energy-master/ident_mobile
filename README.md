# IDent Dynamics — mobile companion

A Flutter app (Android + iOS) for monitoring the sonar streams a user is
subscribed to in [IDent Dynamics](../ident_dynamic). Read-only: authoring,
model editing and the WebGL spectrogram stay in the web app.

## What v1.0 does

1. **Sign in** with the same username/email + password as the web app.
2. **Streams list** — one card per subscribed stream, showing its live time and a
   glowing status light per health check (acoustic data, model runs, AIS feed).
   Tap a card to open its dashboard; tap **Diagnostics** to expand the detail
   in place.
3. **Dashboard** (abridged) — two pages, swapped by tabs or swipe:
   - **Notifications**: detection and AIS-proximity alerts, newest first,
     grouped by day, paged as you scroll. Tap one for a full detail screen; when
     an alert names a single recording, **Open recording** jumps straight to it.
   - **Live images**: opens straight onto the newest recording — there is no
     intermediate file list, because the thumbnail strip *is* the list and is
     always in view. Shows the recording's time span, its spectrogram (pinch to
     zoom, swipe for the next), a favourite star, a date/time search, and the
     detections recorded against that file.

     A **Live / All / Favourites** selector chooses what the strip holds:
     *Live* is every recording pinned to the newest, re-pinning by itself as new
     ones arrive; *All* starts at the newest and then lets you browse freely
     without a background refresh yanking you away; *Favourites* is the starred
     ones only.

**One data flow per screen, at every size.** Notifications and the live feed are
never tiled side by side — each is a distinct thing to read, and splitting the
screen halves both without making either easier to follow.

**Orientation is never forced.** The spectrogram keeps its natural wide aspect
either way; what adapts is the thumbnail strip — along the bottom in portrait,
down the side in landscape, where vertical space is the scarce resource.

If the account's lead has uploaded a company logo, it appears in the home-screen
title bar, mirroring the SPA chrome.

Not in v1.0: sensor map, vessel list, live WebGL render.

## Architecture

```
lib/
  main.dart              App shell; routes on auth state (splash → login → streams).
  src/
    models.dart          Typed views over the API JSON. Parses defensively.
    api_client.dart      Bearer-token HTTP client + ApiException/NetworkException.
    auth.dart            Session state; token in the platform keystore.
    providers.dart       Riverpod graph. Centralises "401 ⇒ sign out".
    theme.dart           Palette lifted from the web app's styles.css.
    time_format.dart     Filename→timestamp parsing and display helpers.
    ui/                  Screens and widgets.
test/                    Unit tests for the parsing logic.
```

**Why no WebGL.** The web dashboard's live render is a WebGL2 displaced-grid
spectrogram. Rather than port that, the images page uses the PNG snapshots the
Brahma service already renders per recording (`brahma/viz/thumbnail.py`, itself
a port of `js/thumbnail.js`). Nothing is decoded on the handset — no audio
download, no STFT — which is what makes a stream of thousands of recordings
scrollable on a phone.

**Why a bearer token.** The web endpoints (`api/*.php`) are gated by cookie
session + CSRF, and `require_login()` *redirects* rather than returning JSON —
unusable from a mobile client. This app talks exclusively to `api/idapi/*`,
which authenticates via `Authorization: Bearer <token>`.

## Backend endpoints this app depends on

Added to the `ident_dynamic` repo alongside this app:

| Endpoint | Purpose |
| --- | --- |
| `api/idapi/login.php` | email/username + password → bearer token. Delegates the credential check to `auth.php`'s `login()`, so IP lockout, the active/verified gates, the audit log and password rehash all still apply. Tears down the cookie session it creates, so the endpoint stays stateless. |
| `api/idapi/logout.php` | Revokes the calling token. |
| `api/idapi/me.php` | Token owner + company branding (resolved through `lead_for_user()`). |
| `api/idapi/diagnostics.php` | Stream health checks. |
| `api/idapi/notifications.php` | Alerts, optionally scoped to one stream, keyset-paged. Carries `file_name` so an alert can be opened to its recording. |
| `api/idapi/stream_thumb.php` | Spectrogram snapshot PNG. |
| `api/idapi/file_decisions.php` | Every detection against one recording, with geometry. Merges database rows and folder sidecars. |
| `api/idapi/favourites_list.php` | Starred recordings in a folder. |
| `api/idapi/favourites_toggle.php` | Star / unstar one recording. |

Supporting changes in the web repo: `lib/favourites.php` (new
`ident_user_favourites` table, created lazily), and a `file_name` column on
`ident_stream_notifications` populated by `scripts/notify_stream_decisions.php`.
Both are added by the existing `ensure_*_table()` helpers, so **no manual SQL
migration is required** — they appear on first use. Notifications written before
the column existed still resolve their recording by parsing `detail`.

Already existed and are reused as-is: `api/idapi/streams_list.php`,
`api/idapi/stream_files.php`.

The three health checks live in `lib/stream_checks.php` in the web repo, shared
by both `api/stream_diagnostics.php` (session) and `api/idapi/diagnostics.php`
(token) — so the phone and the desktop can never disagree about a stream's
health.

## Running it

Requires the Flutter SDK (developed against **3.44.8 / Dart 3.12.2**).

```bash
flutter pub get
flutter analyze
flutter test

flutter run                 # attached device or emulator
flutter build apk           # Android; needs the Android SDK
flutter build ios           # iOS; needs macOS + Xcode
```

At sign-in the server defaults to `https://goident.ai`. **Use a different
server** reveals the field for self-hosted or subdirectory installs (which
`auth.php` supports via `BASE_PATH`).

## Notes for future work

- Notifications are pull-only. Real push would need APNs/FCM and a sender in the
  web app's notification path (`lib/notifications.php`).
- The scrub rail assumes a fixed lane height so index maps to scroll offset
  arithmetically. If lanes become variable-height, the rail needs reworking.
- `parseFileStartTime` mirrors `FILENAME_RE` in `js/decisions.js`, plus a
  tolerant fallback. Recordings whose names carry no timestamp fall back to the
  server's `modified` mtime, so the time axis is never empty.
- **Order recordings by `StreamFile.startTime`, never by `modified`.** The mtime
  is when the writer finished or copied the file, so a downloader that
  backfills or fetches concurrently produces mtimes in a different order from
  the recordings themselves. Sorting on one key while displaying another is
  what made the feed look randomly ordered; `models_test.dart` pins this.
- Only the login screen has been exercised against a live server so far; the
  authenticated screens are verified by static analysis and unit tests, not yet
  by a run against real data.
