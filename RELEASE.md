# Shipping to iOS clients via TestFlight

The route chosen for v1.0 is **TestFlight external testing**: clients install
the real app from a link, without a public App Store listing. It still goes
through Apple's Beta App Review, so most of the App Store bar applies.

What TestFlight costs you against a full listing: **builds expire 90 days after
upload**, so a long-lived client deployment means re-uploading quarterly. What it
saves you: no screenshots, no marketing copy, no App Store product page. If
clients are still on it in six months, move to an unlisted App Store listing —
same binary, same review, no expiry.

---

## One-time setup

### 1. Apple Developer Program

Already enrolled, as an **Individual**. Nothing blocks the first build.

The one consequence to be aware of: on an Individual account the developer name
is fixed to your legal name, and the option to set a trade name is not offered —
it exists only for Organization accounts. So clients installing from TestFlight
see the app published by **Rahul Tandon**, not Vixen Intelligence.

For a pilot that is cosmetic. It stops being cosmetic if the app ever becomes a
listed or unlisted App Store product, where the seller name sits on the product
page. Converting is possible but not self-service: the Team Agent contacts Apple
Developer Support (Contact Us → *Membership and Account* → *Organization Name
Change*) and supplies a company D-U-N-S number, which is free but can take up to
two weeks to issue. Existing apps and the Team ID carry over.

If Vixen Intelligence is the name that should be on this in front of clients,
start the conversion now and keep shipping TestFlight builds under the
individual account while it runs — the two do not block each other. If the
personal name is fine for a pilot, do nothing.

### 2. Bundle ID

Already set to `com.vixenintelligence.identMobile`
(`ios/Runner.xcodeproj/project.pbxproj`). Register it under Certificates,
Identifiers & Profiles, or let Xcode register it for you the first time you
archive with automatic signing. No capabilities need enabling — the app has no
push, no background modes, no App Groups.

### 3. App record in App Store Connect

Create it at <https://appstoreconnect.apple.com> → Apps → +.

- **Name** — must be unique across the entire App Store. "IDent Dynamics" is
  probably free; check before committing, because renaming later is friction.
  This is the app name, and is separate from the developer name discussed
  above — the app can be called IDent Dynamics regardless of account type.
- **Bundle ID** — `com.vixenintelligence.identMobile`
- **SKU** — any internal string, e.g. `ident-mobile-ios`
- **Primary language** — English (UK)

### 4. App Privacy questionnaire

Under the app's **App Privacy** section. What this app actually collects:

| Data type | Collected | Linked to identity | Purpose |
|---|---|---|---|
| Email address / user ID | Yes | Yes | App Functionality |
| Precise location | **No** — sensor and AIS positions come from the server; the device's own location is never read | — | — |
| Usage / diagnostics | No | — | — |

The app requests no runtime permissions at all, which keeps this section short
and keeps the "privacy nutrition label" clean.

### 5. Privacy policy

Required both in App Store Connect metadata and reachable from inside the app.

- Metadata URL: `https://goident.ai/privacy.php` (verified live)
- In-app: a **Privacy policy** link now sits at the foot of the sign-in screen.
  It targets whichever site is in the address field, so self-hosted deployments
  point at their own operator's policy rather than Vixen's.

---

## Per build

### Version and build number

`pubspec.yaml` → `version: 1.0.0+1`. The `+N` build number **must increase on
every upload**, even for a re-upload of an identical binary. Apple rejects a
duplicate outright.

### Archive and upload (on the Mac)

```sh
flutter pub get          # picks up the new url_launcher dependency
flutter build ipa --release
```

No `pod install` step, and running one by hand fails on a fresh clone with
`[!] No 'Podfile' found in the project directory`. The Podfile is generated, not
committed — `flutter build ipa` writes it if it is missing, then runs
`pod install` itself, then archives. To get the Podfile and the xcconfig without
a full build, so the workspace can be opened first, use
`flutter build ios --config-only`.

Then open `build/ios/archive/Runner.xcarchive` in Xcode → **Distribute App**.
(Or `flutter build ipa` then upload `build/ios/ipa/*.ipa` with the **Transporter**
app — same result, fewer dialogs.)

Xcode offers two options that both say TestFlight, and only one of them leads
anywhere:

| Xcode option | Internal testers | External testers | Can ever reach the App Store |
|---|---|---|---|
| **TestFlight & App Store** | yes | yes | yes |
| **TestFlight Internal Only** | yes | **no** | **never** |

Choose **TestFlight & App Store**. An Internal Only build is permanently marked
as such — it cannot be promoted to external testing later, so picking it means
re-archiving under a fresh build number.

"Internal Only" is not a shortcut to clients, because **internal testers must be
App Store Connect users on the account**. Making a client an internal tester
means giving them a login to App Store Connect, which is the wrong trade
entirely. Clients are external testers; that is what Beta App Review is for.

Processing in App Store Connect takes roughly 5–30 minutes before the build
appears under TestFlight.

### "Command PhaseScriptExecution failed with a nonzero exit code"

Building in Xcode from a fresh clone, before the CLI has run, fails here every
time. Both script phases in `Runner.xcodeproj` invoke

```
$FLUTTER_ROOT/packages/flutter_tools/bin/xcode_backend.sh
```

and `FLUTTER_ROOT` is defined in `ios/Flutter/Generated.xcconfig`, which is
gitignored (`ios/.gitignore:21`) because it hardcodes a path to the local
Flutter SDK. Absent, the variable expands to nothing and the phase exits
nonzero. `Podfile` is generated and untracked for the same reason.

So the CLI has to go first — `flutter pub get` writes the xcconfig, and
`flutter build ipa` creates the Podfile and runs `pod install`. Xcode cannot
produce either on its own.

Then open **`ios/Runner.xcworkspace`**, never `Runner.xcodeproj`: with
CocoaPods in the build the bare project omits the Pods and fails much the same
way.

The message itself carries no information — it only says a script phase
returned nonzero. The real error is the line above it, reachable in the Report
navigator (⌘9) by expanding the red `PhaseScriptExecution` row.

### Beta App Review

Only the **first** build for external testing gets a full review; later builds of
the same version usually go straight through. Turnaround is typically under 48
hours.

Fill in, under TestFlight → Test Information:

- **Beta App Description** — what the app is for.
- **Feedback email** — reaches a real inbox.
- **Beta App Review Information** — contact name, phone, email, **and a demo
  account**.

### The demo account is the thing most likely to fail you

The app is unusable without a sign-in, so the reviewer gets nowhere without
working credentials. Create a real `goident.ai` account that is **subscribed to
a stream with actual recent data** — an account with an empty streams list looks
like a broken app, and gets rejected as such.

Put this in the review notes verbatim:

> Sign in with the username and password above. Leave the "IDent Dynamics site
> address" field at its default, `https://goident.ai` — it is only editable for
> customers who self-host the server, and does not need to be changed to review
> the app. After signing in, tap the first stream card to reach the dashboard;
> the four windows (Live images, AIS, Decisions, Notifications) are swiped
> between.

That last paragraph matters. A reviewer who sees an editable server field and no
explanation may read the app as a shell for arbitrary remote content, which is a
guideline 4.2 rejection.

### Adding testers

External testers, up to 10,000: add a group, add emails or enable the **public
link**. A public link is the least friction for clients — no email round-trip,
they just tap it and install TestFlight.

---

## Known risks, in the order they are likely to bite

1. **iPad — settled.** `TARGETED_DEVICE_FAMILY` is now `1`, iPhone only, because
   the app has never been run on an iPad and Apple reviews whatever you declare.
   A layout that breaks there costs a whole review cycle.

   This is reversible in one line, and worth revisiting: a marine monitoring app
   on a vessel is a plausible iPad case. Add iPad back by setting the value to
   `"1,2"` in all three build configurations, *after* exercising the dashboard
   on an iPad simulator — the four-window ring and the thumbnail strip are the
   parts that adapt to size, so they are where it would break. The iPad icon
   sizes are still in the asset catalogue and do not need regenerating.

2. **Account deletion.** Guideline 5.1.1(v) requires in-app account deletion for
   apps that *create* accounts. This app does not — accounts are created on the
   web — so it is arguably exempt, but reviewers flag it often enough that a
   link to the account page is cheap insurance if it comes up.

3. **Cleartext HTTP.** App Transport Security blocks `http://` by default and
   this app ships no exemption, which is the right call for review. The
   consequence is that a self-hosted client on a plain-HTTP install cannot
   connect. They need TLS. Do not add an ATS exception to work around it —
   Apple demands a justification for one and "our customer has no certificate"
   is not accepted.

4. **Map tile terms.** The basemap comes from Esri/ArcGIS and OpenSeaMap. This
   is a commercial product, so check both providers' terms actually permit that
   use. It will not block review — Apple does not check — but it is a live
   business exposure. Attribution is already rendered on the map.

5. **Export compliance.** `ITSAppUsesNonExemptEncryption` is set to `false` in
   `Info.plist`, which stops App Store Connect asking on every single upload.
   That declaration is correct for an app whose only cryptography is HTTPS and
   the iOS Keychain, which is the case here — but it is a legal declaration, so
   satisfy yourself it stays true if crypto is ever added.

---

## Branding assets

The launcher icon and launch screen are generated, not hand-dropped, by
`tool/generate_icons.py`. The icon is the **φ** from the web lockup
(`.logo-phi`), in the wordmark green on the app shell, over range rings that
echo the AIS chart. Rerun after any brand change:

```sh
python3 tool/generate_icons.py
```

It rewrites all 15 iOS icon sizes, the three launch images, and the five Android
mipmaps from one definition, so the sizes cannot drift apart. The iOS 1024px
marketing icon it produces has no alpha channel, which Apple requires.
