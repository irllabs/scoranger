# App Store privacy: the data inventory and the questionnaire answers

Prepared for the public App Store submission of **Scoranger**
(`com.irllabs.scoranger`, IRL Labs LLC, team `V9DBGV72NL`), against
`rel/0.11.0` (marketing version 0.11.0, build 200).

> **AMENDED 2026-09-21 FOR 0.12.0, THE SUBMISSION BUILD.** Four of the defects
> this inventory found were fixed on `rel/0.12.0`, and three of them change
> answers below. Every paragraph they affect is marked **FIXED IN 0.12.0** and
> states both what the code did when this was written and what it does now.
> **Section 5 is the amended questionnaire** — click it through as it stands.
> The changes: dictation is on-device only, so **Audio Data is now No**; the
> OMR cost log no longer carries an email address, so **Email Address is App
> Functionality only**; the chat no longer sends excerpts of earlier prompts;
> and the app has a privacy manifest, closing blocker 4.

Everything here was read out of the code in this repository. Where a fact could
not be established from the code it is marked **UNKNOWN** with the reason.
Nothing is guessed. Section 8 lists the judgment calls that are Ali's to make
and section 9 lists the ones that are a lawyer's.

Companion documents: `design/privacy-policy.md` (Deliverable 2, the text for
the Privacy Policy URL) and `design/support.md` (Deliverable 3, the text for
the Support URL).

**The App Privacy questionnaire has no API.** It is filled in by hand in a
browser in App Store Connect and cannot be read back out. Section 5 is written
so it can be clicked through top to bottom without re-deriving anything.

---

## 1. The four submission blockers

| # | Blocker | State |
|---|---|---|
| 1 | **App Privacy questionnaire** | Answers in section 5. Six judgment calls in section 8 need Ali's decision first. |
| 2 | **Privacy Policy URL** | Text written: `design/privacy-policy.md`. Must be hosted and live before submission. Nothing is published by this work. |
| 3 | **Support URL** | Text written: `design/support.md`. A placeholder page is rejected; the email address in it must be real. |
| 4 | **App-level privacy manifest** | **FIXED IN 0.12.0.** `ios/Scoranger/PrivacyInfo.xcprivacy`, declaring UserDefaults/CA92.1, FileTimestamp/C617.1 and SystemBootTime/35F9.1. See section 7. |

Blocker 4 was found while doing this inventory and is not on anyone's list yet.
Expect the App Store Connect checklist to arrive in waves; budget two or three
rounds of "unable to add for review".

`scoranger.web.app` is already live Firebase Hosting (it serves the
apple-app-site-association for `applinks:scoranger.web.app` and the
`/invite/<id>` landing page). Its content is **not in this repository**
(`firebase/firebase.json` configures firestore, storage, functions and
emulators only, no `hosting` block), so where the policy and support pages get
hosted is Ali's decision and nothing here assumes it.

---

## 2. What a signed-out install does, which is the foundation for everything else

**A signed-out install makes no Firebase contact of any kind.** Not anonymous
auth, not an App Check handshake, not a configuration call.

`FirebaseApp.configure()` is called exactly once in the whole codebase, at
`ios/Scoranger/Account/SignIn.swift:130`, inside `startFirebaseIfNeeded()`, and
its only callers are the three sign-in paths (`SignIn.swift:97`, `:156`,
`:292`). `engine/scripts/check_signed_out.py` is a release gate that refuses
`Auth.auth()` anywhere outside `ios/Scoranger/Account/`. Every other Firebase
entry point guards on `FirebaseApp.app() != nil` and no-ops
(`SharedSetlists.swift:43, 186, 198, 236, 288, 627`; `OMRIdentity.swift:33`).

Sign-in is never required. The library is local, the engine is on-device, and
the app is fully usable without an account (design/FIREBASE.md §0 principle 1).

**Two things still leave a signed-out device**, and this is the part most
likely to be under-declared:

1. **Chat** sends the user's words and the score's structure to
   `openrouter.ai` (section 3.1). No account needed.
2. **"Make editable"** uploads a scan or photograph to the OMR service
   (section 3.3). No account needed; the job is logged as `unattributed`.

And **dictation** streams microphone audio to Apple's speech servers
(section 3.2), also with no account.

---

## 3. Every destination data reaches, traced from the code

The complete set of outbound hosts reachable from app code, from a grep of
every `https://` and `http://` literal under `ios/Scoranger/`:

| Host | What it is | Needs an account? |
|---|---|---|
| `openrouter.ai` | third-party model gateway, the chat agent | no |
| `scoranger-omr-37kxlg2dpa-uc.a.run.app` | Cloud Run, optical music recognition | no |
| Google's Firebase endpoints | Auth, Firestore, Cloud Storage, Functions | **yes, sign-in only** |
| Apple's speech recognition service | dictation | no |
| `MacBook-Pro.local:8765` (user-settable) | a developer escape hatch, off by default | no |
| `scoranger.web.app/invite/<id>` | a link the app *composes*; it does not fetch it | n/a |

`github.com/...` and `scripts.sil.org/OFL` appear only as credit text on the
"How Scoranger works" screen. The Python engine makes no network calls at all
(`grep 'requests\.|urlopen|httpx' engine/scoranger_engine/*.py` finds nothing
but a log line printing a local bind address).

### 3.1 OpenRouter, and the model behind it

`ios/Scoranger/LocalChat.swift:262`. The device calls
`https://openrouter.ai/api/v1/chat/completions` **directly**. There is no
Scoranger-operated relay. The embedded Python engine runs deterministic music21
operations only; `chat.py` is not even vendored into the app bundle.

**The model is a setting, and its default matters.** Fresh installs get
`gemini-flash` = `google/gemini-3.7-flash`
(`LocalChat.swift:18`, populated at `AppState.swift:1846-1852`). The catalog
(`LocalChat.swift:10-18`):

| Setting | OpenRouter slug | Upstream company |
|---|---|---|
| `gemini-flash` **(default)** | `google/gemini-3.7-flash` | Google |
| `kimi` | `moonshotai/kimi-k3` | Moonshot AI |
| `qwen` | `qwen/qwen3.8-max` | Alibaba |
| `claude` | `anthropic/claude-sonnet-5` | Anthropic |
| `claude-opus` | `anthropic/claude-opus-5` | Anthropic |
| `deepseek` | `deepseek/deepseek-v4-flash` | DeepSeek |

No provider-routing object is sent, so **which upstream provider actually
serves a given request is OpenRouter's choice at call time** and is not pinned
in code. `ChatWire.swift:30-33` records this as observed behaviour.

**What is sent.** The body is three keys only: `model`, `messages`, `tools`
(`LocalChat.swift:268-272`).

*Included:*
- the user's typed or dictated message, verbatim;
- the piece name, and **every sibling arrangement's display name and slug**,
  unconditionally in the system message (`AppState.swift:3580-3596`);
- when a lasso selection is active, the selection headline and the literal
  element addresses (`AppState.swift:3601-3625`);
- the **full prior conversation**, every turn (`AppState.swift:3816`);
- after the model calls `get_score_info`, which the system prompt instructs it
  to do first: **title, composer, arranger**, and per part the name,
  abbreviation, instrument, clefs, pitch range, measure count and note count,
  plus key and time signatures (`engine/scoranger_engine/ops.py:4621-4652`);
- chord symbols and lyric text the user asks to be written, inside the tool
  arguments the model generates;
- via the `list_versions` tool, **in 0.12.0**: each version's id, operation
  and arguments, and per source its id, name and part structure — and nothing
  else (`engine/scoranger_engine/workspace.version_history`). *Through 0.11.0
  this also sent artifact **filenames**, document uids and **up to 200
  characters of each previous user prompt**; see the note at the end of this
  section;*
- engine error strings verbatim, which deliberately quote real part names
  (`LocalChat.swift:37-38, 237-242`).

*Not included:* no MusicXML or MEI bytes, no audio, no images, no PDFs, no ink,
no setlists, and **no user identifier of any kind**: no uid, no email, no
`identifierForVendor`, no `user` field. Verified by reading the payload builder
and the full header set.

*Headers* (`LocalChat.swift:265-278`): `HTTP-Referer:
https://github.com/irllabs/scoranger`, `X-Title: Scoranger`, and the bearer
key. These identify the app, not the person.

**From 0.15.0 the API key is the READER'S OWN** (Ali, 2026-09-23). `ChatKey`
(`ios/Scoranger/ScoreModel/ChatKey.swift`) is the whole rule: the key the
reader saved in Settings, kept in the Keychain and sent only to OpenRouter, or
none -- in which case chat says where to get one and does not run. The app
ships no key: `project.yml` deletes `openrouter-default-key.txt` on every
build, and `deploy_testflight.sh` refuses an archive in which any file contains
an OpenRouter key.

*Through 0.14.0 it was the developer's, shared by every install:* baked into
the bundle from the gitignored `.env`, used whenever the reader had saved none,
and written into the reader's Keychain by a 401 "self-heal" that replaced a
refused key without a word. `RetiredKeys` makes a device forget that one key at
launch, by its SHA-256; revoking it at OpenRouter is what kills every copy.

**What this does to the App Privacy answers** (for Ali, section 8): chat
traffic now goes from the device to OpenRouter under the READER'S account, and
never reaches the developer. The answers in section 5 were written for the
developer's account and are still the conservative reading. Whether content
sent to a service the reader holds their own account with is "collected" by
this app is a judgement call for section 8, not a fact this inventory can settle.

**No retention control is requested.** No zero-data-retention header, no
`provider` routing block, no `transforms`, so the ACCOUNT'S settings apply --
now the reader's own, which the policy says, and suggests turning logging and
training off. (Through 0.14.0 that account was the developer's, and both were
confirmed off, 2026-09-22.)

**FIXED IN 0.12.0: the `list_versions` asymmetry.** Through 0.11.0 the Python
agent projected version documents down to `{id, op, args}` while the iOS
bridge returned `load_meta` unfiltered — so the surface on the device Ali's
family uses put artifact filenames, document uids and 200-character excerpts
of earlier user prompts on the wire, and the desktop one did not.

Both now call one projection, `workspace.version_history`. Sources were
narrowed at the same time, to `{id, name, parts}`: the desktop path had been
sending each source's `file` and `origin`, a filename and a path off the
user's disk. `load_meta` itself is unchanged — the CLI, the manifest and the
app's own UI read it and want the whole document.

Nothing depended on the wider payload; the only readers of the bridge op's
result are a check that counts the versions and the chat itself. Held by
`engine/scoranger_engine`'s `check_version_history.py`, which drives a real
score with a real chat turn open and searches the serialised answer for the
prompt text **by value**, so a prompt reaching the model under a different key
is still caught.

### 3.2 Apple speech recognition, for dictation

**FIXED IN 0.12.0. No dictation audio leaves the device, and there is no
path on which it can.**

*What it did through 0.11.0.* `SFSpeechRecognizer()` was default-initialised
and `requiresOnDeviceRecognition` was never set anywhere in the repository —
zero matches across all Swift — so it defaulted to `false` and microphone
audio was streamed to Apple's servers on every device, including ones that
support on-device recognition. The Info.plist strings did not mention a
server.

*What it does in 0.12.0* (`ios/Scoranger/SpeechDictation.swift`).
`requiresOnDeviceRecognition = true`, and where `supportsOnDeviceRecognition`
is false the app **refuses to dictate** and says so in the chat field's
placeholder, rather than falling back to the network. A fallback was
considered and rejected: the user cannot tell which of the two ran, so no
honest permission string could be written for it. Dictation is one alternative
way to type into a text field; the keyboard is always there.

The guard runs before the audio session opens, so a device that cannot do this
never records at all.

Both Info.plist strings now say where the audio goes: *"Dictate arrangement
requests. Speech is transcribed on this device and is not sent anywhere."* and
the microphone equivalent. They are set in `ios/project.yml` as well as
`Info.plist`, because Xcode regenerates the built plist from `project.yml`.

The chain is now: microphone → on-device transcription → text in the chat
draft (`ChatView.swift:291-295`) → OpenRouter, which the user typed-or-spoke
either way.

**Audio Data in section 5 is "No".** Held by
`engine/scripts/check_dictation.py`, which reads the source with comments
stripped and fails both on the flag being absent and on it being assigned from
anything other than the literal `true`.

### 3.3 The OMR service: the user's own sheet music goes to a server

`omr-service/`, deployed to **Google Cloud Run**, service `scoranger-omr`,
region **us-central1**, `--allow-unauthenticated` at the platform level with
app-level auth inside (`omr-service/deploy.sh:44-45, 82-88`). Audiveris 5.11.0
in a container. The Firebase project is `scoranger`; the GCP project **ID** is
UNKNOWN (deploy.sh uses the ambient `gcloud` config; only the project *number*
`789974749678` appears, at `AppState.swift:922`).

**A photograph or scan leaves the device only on an explicit tap.** Importing a
scan does nothing over the network (`AppState.swift:2474-2483`); the only path
off-device is **"Make editable"** → `makeEditable()` → `convertPDF` →
`POST /jobs`. There is no camera capture code in the app at all: no
`VNDocumentCameraViewController`, no `UIImagePickerController`. Images arrive
through the out-of-process `PHPickerViewController`, which needs no photo
library permission and shows no prompt (`Navigation/PhotoImport.swift:12-36`),
or through Files and the share sheet.

**What is uploaded** (`AppState.swift:2665-2696`): the **raw PDF bytes** as the
request body, and nothing else. A photograph is first wrapped into a one-page
PDF (`ScoreModel/ScanImage.swift:101-114`); an oversized or vector PDF is
re-rendered to Letter at 300 DPI (`PDFPreflight.swift:56-70`); an ordinary scan
passes through byte for byte. No multipart, no `Content-Disposition`, so **no
filename**. No score title, no slug, no device identifier.

**Two headers carry identity:**
- `X-API-Key`, a shared secret baked into every bundle from the gitignored
  `.omr-api-key` (`ios/project.yml:128`).
- `Authorization: Bearer <Firebase ID token>` — **only when signed in**
  (`Account/OMRIdentity.swift:32-45`). The JWT carries the Firebase uid and,
  for most providers, the email address.

**FIXED IN 0.12.0: the service no longer writes any email address.**

*What it did through 0.11.0.* `omr-service/identity.py` emitted one JSON line
per finished job carrying `{omr_usage, job, actor: "uid:<firebase uid>",
trust, pages, seconds, outcome, **email**, at}`, on every exit path including
timeout and failure. Cloud Logging is durable by design and `deleteAccount`
makes no Logging call, so that address outlived the account it belonged to —
for every user, not only the known child one. This was the sharpest edge in
the inventory.

*What it does in 0.12.0.* The line is
`{omr_usage, job, actor, trust, pages, seconds, outcome, at}`. `actor` still
carries `uid:<firebase uid>`, which is what per-user cost accounting
multiplies against `pages`; the address was read by nothing else, and
design/FIREBASE.md §0.12's own description of the record never listed it.

Removed at the source rather than filtered downstream: `actor_for` answers
`(actor, trust)` and no longer reads the `email` claim, `usage_line` has no
parameter to pass one to, and the job record `server.py` keeps between
acceptance and billing has no `email` key. Held by
`engine/scripts/check_omr_attribution.py`, which drives a token whose claims
*do* carry an address and asserts none of it reaches the line.

**This changes the Email Address row in section 5: the Analytics purpose was
this log, and it is gone.**

Two more logging facts:
- `server.py:309-310` logs byte length, User-Agent and the **first 8 bytes** of
  the PDF (the `%PDF-1.x` magic). A format check, not content.
- On a failed conversion, `server.py:205-206` prints up to **2,000 bytes of
  Audiveris's own log tail**. Audiveris's OCR step reads titles, lyrics and
  chord symbols off the page, so **recognised text from the user's sheet music
  can land in Cloud Logging** for scores that fail. Incidental, but real.

**Retention of the uploaded file:** a per-job `tempfile.mkdtemp` inside the
container, purged at a 3,600-second TTL (`server.py:61, 145-151`), and gone
when the instance recycles. **No Cloud Storage write, no Firestore write, no
database.** Verified: the only dependency is `PyJWT[crypto]==2.10.1` and grep
for `storage|bucket|gcs|blob|firestore` across the service finds nothing.

**Retention of the log line: UNKNOWN.** No log router, log bucket or retention
policy exists anywhere in the repository; it defaults to whatever the GCP
project's `_Default` bucket is set to. *Ali must establish this number before
the privacy policy can state a retention period honestly.*

### 3.4 Firebase Auth

`Account/SignIn.swift`. Two providers: Sign in with Apple and Google Sign-In.
Apple sign-in requests the `.fullName` and `.email` scopes
(`SignIn.swift:273`).

What Firebase Auth holds per user (`SignIn.swift:336-348`): the **uid**, the
**email address** (kept even when it is an Apple Hide My Email relay address,
because an invitation has to be addressed to something), the **display name**,
and the provider. Firebase adds its own creation and last-sign-in timestamps.
Where a verified address matches across providers the second credential is
linked to the first account rather than creating a second
(`SignIn.swift:320-333`).

Nothing else is written about a person. **There is no `users/{uid}` profile
document written by any client.** The Firestore rule exists
(`firebase/firestore.rules:44`) but grep finds no writer in Swift or in the
Cloud Functions.

### 3.5 Firestore: shared set lists

`Account/SharedSetlists.swift` and `firebase/functions/index.js`. Only reached
after sign-in, and only for set lists the user chose to share.

| Collection | Fields written | Who is identified |
|---|---|---|
| `setlists/{id}` | `name`, `ownerId`, `members` (uid → role), `memberIds`, `createdAt` | uids only |
| `setlists/{id}/entries/{id}` | `title`, `composer`, `versionLabel`, `order`, `scoreUid`, `versionUid`, `mode`, `provenance`, `storagePath`, `bytes`, `sha256`, `addedBy`, `addedAt`, and on removal `removedAt`/`removedBy` | uid |
| `setlists/{id}/entries/{id}/ink/{uid}` | `layer`, `pageWidth`, `updatedAt`, `pages` (page number → PencilKit drawing data) | **the document id is the uid** |
| `memberships/{uid}_{setlistId}` | `userId`, `setlistId`, `setlistName`, `role`, `succession`, `joinedAt` | uid |
| `invites/{id}` | `setlistId`, `setlistName`, **`emailLower`**, `claim`, `expiresAt`, `revokedAt`, `claimCount`, `invitedBy`, `invitedAt`, and on claim `acceptedBy`/`acceptedAt` | uid, **plus a third party's email address** |

Two things to notice.

**No display names or email addresses are stored on the set list itself.** The
`members` map is uid → role. A member is an opaque id to everyone but Firebase
Auth.

**`invites.emailLower` is an email address the user typed for somebody else.**
Apple counts data a user provides about other people as collected data. It is
the invitee's address, normalised to lower case, and it persists in the invite
document. Invites expire after seven days (`functions/index.js`, `WEEK_MS`).

**An invitation can be an open link, and the design document says it cannot.**
`design/FIREBASE.md` §8.2 guard rail 1 states "Sharing is to named people,
never to a link. No 'anyone with the link' mode, in v1 or later." The shipped
code does not match that. `SharedSetlists.invite(to:email:)`
(`SharedSetlists.swift:406-410`) sends `claim: "open"` when no address is
given, and two UI paths do exactly that: the main share action
(`ShareSetlistAction.swift:45` → `promote()` → `invite(to:email: nil)`) and the
"copy link" control (`SharedSetlistScreen.swift:245`). The addressed form is
the *other* button (`SharedSetlistScreen.swift:344`).

`claimInvite` (`functions/index.js`) does constrain an open link: the claimant
must be signed in with a **verified** email address, the link expires after
seven days against the server clock, it is refused once the set list reaches
twelve members, and it can be revoked. So it is not public redistribution. But
it is "anyone with the link who has an account", not "a named person", and the
privacy policy and support page have to describe what the code does. Both do.

This is a documentation-versus-code divergence, not a defect found in this
work, and it is recorded rather than fixed. It bears on the copyright posture
that §8.2 says rests on guard rail 1.

`libraries/{libraryId}` rules exist in both `firestore.rules:54` and
`storage.rules` for a future private-library backup. **No client code reads or
writes them today** (grep across `ios/Scoranger/` and `engine/` finds nothing).
Private library sync is not shipping, so nobody's whole library is uploaded.

### 3.6 Cloud Storage

`storage.rules`. **Nothing is public. Not one path.**
(`allow read, write: if false` on `/{allPaths=**}` before any other rule.)

The only path the app writes is
`shared/{setlistId}/{entryId}/{versionUid}.musicxml` or `.pdf`
(`SharedSetlists.swift:468-471`): **the actual sheet music of an arrangement
the user shared**, readable by the members of that one set list and nobody
else. Twelve members maximum, enforced in the rules.

Books and sources never share, by design and with no affordance anywhere
(design/FIREBASE.md §8.2 guard rails 3 and 4).

### 3.7 Cloud Functions

Region `us-west1`. `shareSetlist`, `createInvite`, `claimInvite`,
`revokeInvite`, `removeMember`, and on `feat/account-deletion`, `deleteAccount`.
Every one requires an authenticated caller. They see the caller's uid and, in
`claimInvite`, the verified email claim from the ID token
(`functions/index.js:161`).

### 3.8 The local-network engine, which is a developer escape hatch

`@AppStorage("useLocalEngine") var useLocalEngine = true`
(`AppState.swift:821`). The default is the on-device engine. But Settings →
Engine exposes a **"Use on-device engine" toggle and an editable server URL**
(`SettingsView.swift:151-192`), defaulting to `http://MacBook-Pro.local:8765`
(`ios/project.yml:771`), and `NSAllowsLocalNetworking: true` is set.

Turned off, the app posts the score slug, the chat message, the model name and
the history to that host **over plaintext HTTP**. It is a developer
convenience that ships in the public build, visible to any user in Settings.
Recorded, not fixed. Worth considering whether it should be hidden in a
release configuration before the public store listing.

---

## 4. What Firebase collects by default that nobody chose: nothing

This was the question most worth being exact about, and the answer is good.

**Firebase Analytics is not linked.** Verified two independent ways:

1. **Requested products** (`ios/project.yml:77-89`) are `FirebaseAuth`,
   `FirebaseFirestore`, `FirebaseStorage`, `FirebaseFunctions` and
   `GoogleSignIn`. No Analytics, Crashlytics, App Check, Messaging,
   Installations, Performance, RemoteConfig or DynamicLinks.
2. **Linked objects in the built product.** The complete set of SPM `.o` files
   in the most recent build contains no `FirebaseAnalytics.o`, no
   `GoogleAppMeasurement`, no `FirebaseCrashlytics.o`, no
   `FirebaseInstallations.o`, no `GoogleDataTransport.o`. In the shipped
   archive binary, `strings` for `GoogleAppMeasurement`, `AppMeasurement`,
   `app_measurement`, `APM[A-Z]` and `firebase_screen` returns **zero hits
   each**, as do `FIRCrashlytics`, `FIRInstallations` and `FIRPerformance`.

SPM *resolves and checks out* `GoogleAppMeasurement 11.15.0` and
`google-ads-on-device-conversion 2.3.0`, because firebase-ios-sdk declares them
for products this app does not use. **Resolution is not linkage.** They are not
in the binary.

The `FIRAnalyticsConfiguration` strings that do appear live in FirebaseCore,
which reads the Info.plist analytics flags; with no measurement library linked
there is no code to run. `GoogleService-Info.plist` carries
`IS_ANALYTICS_ENABLED = false` and `IS_ADS_ENABLED = false`.

**No analytics, crash, installations, App Check or performance API is called
anywhere in Swift.** Grep for `Analytics.`, `logEvent`, `Crashlytics`,
`setAnalyticsCollectionEnabled`, `Installations`, `AppCheck`,
`FirebasePerformance` across the app, tests and UI tests: zero hits.

Also absent from the whole codebase: `ATTrackingManager`,
`AppTrackingTransparency`, `advertisingIdentifier`, `identifierForVendor`,
`CoreLocation`, `Contacts`/`CNContactStore`, CloudKit, HealthKit. No
`NSUserTrackingUsageDescription`, no `GADApplicationIdentifier`, no
`NSCameraUsageDescription`, no `NSPhotoLibraryUsageDescription` in the
Info.plist.

Local instrumentation (`ScoreModel/PerfMetrics.swift`, `TouchDiagnostics.swift`)
uses `os_signpost` and UserDefaults. Nothing uploads.

**Resolved SDK versions** (`ios/Scoranger.xcodeproj/.../Package.resolved`):
firebase-ios-sdk **11.15.0**, GoogleSignIn-iOS **8.0.0**, GoogleUtilities 8.1.3,
grpc-binary 1.69.1, SwiftDraw 0.29.0. Note the `project.yml` pins are
open-ended `from:` floors (`from: 11.9.0`, `from: 8.0.0`), so linkage is pinned
only by the checked-in `Package.resolved`. **A `swift package update` could
pull a different 11.x and change these answers.** Re-verify section 4 after any
dependency bump; the check is a `strings` grep for `GoogleAppMeasurement` on
the archive binary.

---

## 5. The App Privacy questionnaire, filled in

Read down the page. Apple's structure, Apple's category names.

**Preliminary questions**

| Question | Answer |
|---|---|
| Does your app collect any data? | **Yes** |
| Do you or your third-party partners use data for tracking? | **No** (no ATT prompt, no IDFA, no ad SDK, no data broker; see section 4) |
| Third-party advertising | **No** |

Apple's definition of "collect" is transmitting data off device where it is
accessible for longer than needed to service the request in real time. The
on-device library and the on-device engine are therefore not collection.

### Contact Info

| Data type | Collected | Linked to identity | Used for tracking | Purposes |
|---|---|---|---|---|
| **Email Address** | **Yes** | **Yes** | No | App Functionality *(Analytics dropped in 0.12.0 — see §3.3)* |
| **Name** | **Yes** | **Yes** | No | App Functionality |
| Phone Number | **No** *(see 8.1)* | — | — | — |
| Physical Address | No | — | — | — |
| Other User Contact Info | No | — | — | — |

*Email:* **two** flows in 0.12.0. The account's own address in Firebase Auth
(§3.4), and the invitee's address the user types into an invitation, stored as
`invites.emailLower` (§3.5). Both are App Functionality. The third flow — the
signed-in user's address written into the OMR service's Cloud Logging cost
records — was the Analytics purpose, and it no longer exists (§3.3).

*Name:* the display name Apple or Google supplies at sign-in, held by Firebase
Auth (§3.4). Never written to Firestore.

Both are collected **only if the user signs in**. Apple's questionnaire has no
"optional feature" qualifier, so the answer is Yes.

### Health & Fitness, Financial Info, Location, Sensitive Info, Contacts

| Data type | Collected |
|---|---|
| Health, Fitness | **No** |
| Payment Info, Credit Info, Other Financial Info | **No** |
| Precise Location, Coarse Location | **No** *(see 8.2)* |
| Sensitive Info | **No** |
| Contacts (the address book) | **No**. No Contacts framework anywhere; an invitee's address is typed by hand and is declared above as Email Address |

### User Content

| Data type | Collected | Linked to identity | Used for tracking | Purposes |
|---|---|---|---|---|
| **Photos or Videos** | **Yes** | **Yes** | No | App Functionality |
| Audio Data | **No** *(0.12.0: dictation is on-device only — see §3.2)* | — | — | — |
| **Other User Content** | **Yes** | **Yes** | No | App Functionality |
| Emails or Text Messages | No | — | — | — |
| Gameplay Content | No | — | — | — |
| Customer Support | No | — | — | — |

*Photos or Videos:* a photograph of sheet music, wrapped into a PDF and
uploaded to the OMR service when the user taps "Make editable" (§3.3). Linked,
because a signed-in user's job carries their Firebase ID token and their uid
and email are logged against it.

*Audio Data:* **No, as of 0.12.0.** Dictation sets
`requiresOnDeviceRecognition = true` and refuses where on-device recognition
is unavailable, so no recording leaves the device and none is collected
(§3.2). Through 0.11.0 this was Yes / not linked. Judgment call 8.3 is
therefore moot.

*Other User Content:* four things. The sheet music files uploaded to Cloud
Storage for a shared set list (§3.6). The pencil ink drawn on shared pages,
stored per uid in Firestore (§3.5). From 0.16.0, **a signed-in account's whole
library** -- every arrangement and version, their sources, pieces, set lists
and books, with the music and book files -- kept under
`libraries/{libraryId}` in Firestore and Cloud Storage, owned by that uid and
readable by it alone (firestore.rules, storage.rules), so the library is the
same on every device the account signs in on; deleted with the account by the
`deleteAccount` Function. And the chat conversation sent to OpenRouter (§3.1)
together with the score's title, composer, arrangement names and part
structure. The first three are linked to a uid. The fourth carries no
identifier at all but is grouped here because the data type is the same; see
8.4. **The label does not change for 0.16.0**: Other User Content was already
Collected, Linked, App Functionality.

### Browsing History, Search History, Purchases

| Data type | Collected |
|---|---|
| Browsing History | **No** |
| Search History | **No** |
| Purchase History | **No**. No in-app purchase, no StoreKit |

### Identifiers

| Data type | Collected | Linked to identity | Used for tracking | Purposes |
|---|---|---|---|---|
| **User ID** | **Yes** | **Yes** | No | App Functionality; Analytics |
| Device ID | **No** *(see 8.1)* | — | — | — |

*User ID* is the Firebase uid. It is written to Firestore as `ownerId`,
`addedBy`, `invitedBy`, `removedBy`, as the `members` map key and as the ink
document id, and it is logged against every attributed OMR job. The Analytics
purpose is that last one: per-user OMR cost accounting.

### Usage Data

| Data type | Collected | Linked to identity | Used for tracking | Purposes |
|---|---|---|---|---|
| **Product Interaction** | **Yes** | **Yes** | No | Analytics |
| Advertising Data | **No** | — | — | — |
| Other Usage Data | **No** | — | — | — |

*Product Interaction:* the OMR usage record, one line per conversion carrying
page count, seconds taken and outcome, attributed to a uid (§3.3). That is the
only usage data the project collects, and it exists to meter server cost. No
screen views, no taps, no session data, no funnel.

### Diagnostics

| Data type | Collected | Linked to identity | Used for tracking | Purposes |
|---|---|---|---|---|
| Crash Data | **No**. No Crashlytics; Apple's own store-level crash reporting is Apple's, not the developer's | — | — | — |
| Performance Data | **No**. `PerfMetrics` is `os_signpost` and UserDefaults, local only | — | — | — |
| **Other Diagnostic Data** | **Yes** *(see 8.5)* | No | No | Analytics |

*Other Diagnostic Data:* the FirebaseAuth and FirebaseFirestore privacy
manifests bundled with SDK 11.15.0 both declare `OtherDiagnosticData`, not
linked, purpose Analytics. Declaring it matches what ships. Additionally the
OMR service logs a User-Agent string and byte counts per request.

### Other Data

| Data type | Collected |
|---|---|
| Other Data Types | **No**. Everything found is classifiable above |

### Summary of every "Yes"

**Seven** data types in 0.12.0, in the order the questionnaire presents them.
Audio Data was the eighth and is now No (§3.2); Email Address has lost its
Analytics purpose (§3.3). These seven are also what
`ios/Scoranger/PrivacyInfo.xcprivacy` declares, and a check fails if the two
lists disagree.

| # | Data type | Linked | Purposes |
|---|---|---|---|
| 1 | Email Address | linked | App Functionality |
| 2 | Name | linked | App Functionality |
| 3 | Photos or Videos | linked | App Functionality |
| 4 | Other User Content | linked | App Functionality |
| 5 | User ID | linked | App Functionality, Analytics |
| 6 | Product Interaction | linked | Analytics |
| 7 | Other Diagnostic Data | not linked | Analytics |

Tracking: **No**, on every one.

---

## 6. Account deletion, which App Review guideline 5.1.1(v) requires

Built on branch **`feat/account-deletion`** (not yet merged into `rel/0.11.0`).
**It must be in the submitted build.** Guideline 5.1.1(v) requires in-app
account deletion for any app that supports account creation.

Path: Settings → Account → "Delete my account", a destructive row with a
two-step inline confirm. Fully self-service: no email, no web form, no waiting
period, no support ticket.

What it does, in order:
1. Apple accounts only: a fresh authorization run and
   `Auth.auth().revokeToken(withAuthorizationCode:)`, which is Apple's
   token-revocation requirement. If Apple returns no code, nothing is deleted.
2. The `deleteAccount` callable Function (us-west1):
   - set lists owned with other members are **handed on** to the next person
     invited (lowest `succession`), never destroyed;
   - set lists owned alone are **destroyed**, with their entries, their
     Cloud Storage prefix and their invites;
   - set lists the user only belonged to **survive**, with the user removed
     from `members` and `memberIds`;
   - the user's **own ink is deleted** from every surviving set list, and
     nobody else's;
   - `memberships/*`, `users/{uid}` and any `libraries` owned are deleted;
   - invitations the user minted into surviving lists are **revoked, not
     deleted** (an open link outliving its account is a live credential), so
     `invitedBy: <uid>` persists in those documents;
   - `getAuth().deleteUser(uid)` runs **last**, so a mid-flight failure leaves
     an account that can sign in and retry.
3. The local library on the iPad is untouched, and the confirmation says so.

**Two retention facts the policy has to state honestly:**

- Revoked invite documents keep the deleted user's uid.
- **Account deletion does not reach the OMR usage logs.** The uid and email in
  Cloud Logging (§3.3) live in a different subsystem the Function never
  touches. A deleted user's address remains there for whatever the project's
  log retention is. This is a genuine cross-cutting gap, and it is a gap in the
  *deletion promise*, not just in the documentation.

---

## 7. Blocker 4: the app's privacy manifest — FIXED IN 0.12.0

`ios/PrivacyManifests/` holds exactly two files, `_ssl.xcprivacy` and
`_hashlib.xcprivacy`, hand-written for the embedded CPython OpenSSL extension
modules and seeded into the Python payload at build time
(`ios/scripts/seed_privacy_manifests.sh`) to clear the ITMS-91061 warnings that
blocked external TestFlight on 0.6.15.

*Through 0.11.0 there was no `PrivacyInfo.xcprivacy` for the Scoranger app
target at all* — not in `ios/Scoranger/`, not in the project, not at
`Scoranger.app/PrivacyInfo.xcprivacy` in the archive. **0.12.0 adds
`ios/Scoranger/PrivacyInfo.xcprivacy`**, picked up by the app target's
resources build phase.

The app uses `UserDefaults` / `@AppStorage` in nine files
(`AppState`, `ScorangerApp`, `SettingsView`, `ChatView`, `TestReset`,
`TouchDiagnostics`, `PerfMetrics`, `SharedEntryCopies`, `SignInMemory`).
`NSPrivacyAccessedAPICategoryUserDefaults` is a required-reason API; the app's
own use of it needs the app's own manifest with reason **CA92.1** ("access info
from same app, per documentation"). Every bundled SDK declares its own; the app
declares none. Expect **ITMS-91053, "Missing API declaration"**.

**What 0.12.0 declares, and how it was decided.** Read off the compiled app
binary's undefined symbols rather than off a grep of Swift, because SPM
packages that build as **static** libraries are linked *into* the app binary
and are the app's to declare:

| Category | Reason | What puts it in the binary |
|---|---|---|
| `UserDefaults` | `CA92.1` | `_OBJC_CLASS_$_NSUserDefaults` and SwiftUI's `AppStorage` initialisers, from the nine files above. App-private: no `suiteName` and no app group anywhere in the target |
| `FileTimestamp` | `C617.1` | `_stat` and `_fstat`, from `VerovioCore.o` and `leveldb.o`. leveldb declares its own in a resource bundle; **Verovio is a local SPM package with no manifest**, so its file access is undeclared by anyone but the app |
| `SystemBootTime` | `35F9.1` | `_CACurrentMediaTime`, in `PerfMetrics` and the page view's frame loop |

The Swift-only survey in the paragraph above was **wrong in one direction**:
it found no file-timestamp reads in app *code*, which was true, and concluded
none were in the app *binary*, which was not. Verovio is the reason.

`SystemBootTime` is deliberately wider than the letter of Apple's list, which
names `systemUptime` and `mach_absolute_time` rather than the `CACurrentMediaTime`
wrapper. It is the same boot-relative clock, used to measure elapsed time
within the app, which is what `35F9.1` describes — and over-declaring is the
safe direction.

**Not declared, because no symbol in the binary backs them:** Disk Space (no
`statfs`, `statvfs`, `fstatfs`, `fstatvfs`, `volumeAvailableCapacity`) and
Active Keyboards (no `activeInputModes` in the symbol table or the strings).

It carries `NSPrivacyTracking = false`, `NSPrivacyTrackingDomains = []`, and
the seven collected data types of section 5.

**Two enforcement points.** `engine/scripts/check_privacy_manifests.py` §0
reads the built binary and fails on *under*-declaring, and reports (without
failing) any category declared that no symbol backs. `ios/scripts/deploy_testflight.sh`
refuses to upload an archive whose app has no manifest, or whose manifest
declares nothing.

---

## 8. Six judgment calls that are Ali's, not mine

These are places where the code gives a clear fact and the questionnaire still
needs a decision. Each has a recommendation.

**8.1 GoogleSignIn's own manifest declares more than Scoranger asks for.**
The `GoogleSignIn_GoogleSignIn.bundle` privacy manifest in SDK 8.0.0 declares
collection of `Name`, `EmailAddress`, **`PhoneNumber`**, **`CoarseLocation`**,
`UserID`, **`DeviceID`** and `OtherUsageData`, some with an Analytics purpose.
Scoranger asks for none of those last three and has no location or telephony
code. Apple aggregates SDK manifests into the app's privacy report
independently of the questionnaire, so the report and the questionnaire can
disagree.
*Recommendation: answer No to Phone Number, Coarse Location and Device ID. That
data is collected by Google for Google's own account-security purposes as an
independent controller, not on Scoranger's behalf. Be ready to say so if App
Review asks. The counter-argument (declare them, since you chose to bundle the
SDK) is defensible too and costs nothing but a scarier privacy label.*

**8.2 Location.** Same question, narrower. No `CoreLocation` import exists
anywhere. Firebase and Google infer coarse location from IP at their end.
*Recommendation: No. IP-derived location at a service provider is not app
collection.*

**8.3 Audio Data.** Apple's guidance exempts data processed on device. Server
speech recognition is not on device, but the processor is Apple itself, and the
audio is never associated with a Scoranger account.
*Recommendation: declare it, Not Linked, App Functionality. It is the honest
answer and it costs one label row. Better still, set
`requiresOnDeviceRecognition = true` with a `supportsOnDeviceRecognition`
fallback, re-verify, and answer No.*

**8.4 Is the chat content "linked to the user"?** The OpenRouter payload
carries no uid, no email, no device id. It does carry the device's IP address
inherently, the developer's shared API key, and titles and arrangement names
the user chose, which can themselves be identifying ("Ali's wedding set").
*Recommendation: Linked, because Other User Content is already Linked via the
Cloud Storage and ink paths, so the label does not change; answering Linked
avoids a distinction you would have to defend.*

**8.5 Other Diagnostic Data.** Declaring it matches the bundled Firebase
manifests. Not declaring it is arguable, since it is the SDK's telemetry rather
than the app's.
*Recommendation: declare it. Not linked, Analytics. One row, no downside, and
it matches the aggregated privacy report Apple will generate.*

**8.6 Is OMR cost metering "Analytics" or "Other Purposes"?** Apple defines
Analytics as evaluating user behaviour and feature effectiveness. Metering
server spend per user is closer to billing.
*Recommendation: Analytics. "Other Purposes" invites a follow-up question and
Analytics is the closer of the offered boxes.*

**And one thing that is not a judgment call: check the OpenRouter account.**
Whether logging and training are disabled on the account behind the baked key
is a dashboard setting outside this repository, and the privacy policy makes a
statement about it. Verify it before the page goes live.

---

## 9. The child-account question, for a lawyer

**Do not try to resolve this here.** It is flagged, with the facts that bear on
it, and nothing more.

**The situation.** Ali's son, under 13, uses Scoranger with a supervised Apple
account. Sign in with Apple exists in this app substantially because of him:
`ios/Scoranger/Scoranger.entitlements` says so in a comment, "Ali's son has an
Apple account and no Google one, so this is not a nice-to-have: without it he
cannot join a shared set list at all."

Collecting personal information from a child under 13 engages **COPPA** and its
verifiable-parental-consent requirement, and separately engages App Review
guidelines 1.3 and 5.1.4 and Apple's Kids Category rules. **Neither I nor Ali
is qualified to decide whether it applies here.**

### The facts a lawyer will need

**Can a child sign in? Yes, with nothing in the way.**
There is no age gate, no birthdate field, no age-screening step, and no
parental-consent flow anywhere in the app. Verified by grep across
`ios/Scoranger/Account/` and `SettingsView.swift` for `age`, `child`,
`parental`, `COPPA`, `minor`, `birth`: zero relevant hits. Sign in with Apple
with a Family Sharing child account is a supported Apple flow and the app does
nothing to detect or refuse it.

**What is collected from a child who signs in:**
- Firebase uid, email address (possibly an Apple private relay address), and
  display name, held by Firebase Auth (§3.4).
- Their pencil ink, stored per uid under every shared set list entry they mark
  up, readable by up to eleven other members (§3.5).
- Any sheet music they add to a shared set list, in Cloud Storage (§3.6).
- Their email address, written to Google Cloud Logging on every scan they
  convert, with retention UNKNOWN (§3.3).
- Email addresses of anybody they invite (§3.5).

**What is collected from a child who does *not* sign in:**
- Nothing at all reaches Firebase (§2, and it is enforced by a release gate).
- But their typed or dictated words, the titles and composers of their music,
  and their arrangement names still go to **OpenRouter and on to a
  third-party model provider** (§3.1), with no identifier attached.
- And their **voice** still goes to Apple's speech servers (§3.2).
- And a scan they convert still goes to the OMR service, logged as
  `unattributed` (§3.3).

**What the app would have to not do for the question to be moot.** Roughly, in
descending order of how much it removes:
1. **No sign-in for the child.** That alone removes every identity-linked item
   above: uid, email, name, ink attribution, uploaded files, and the logged
   email. The app is fully usable signed out and the local library is
   untouched.
2. **No chat.** Removes free-text and score metadata going to a third-party
   model provider. This is the one that is not solved by staying signed out.
3. **No dictation, or on-device dictation only.** Removes the child's voice
   leaving the device. A one-line change makes this true (§3.2).
4. **No OMR, or OMR with no logged identity.** Removes the email in Cloud
   Logging and the page images going to a server.

**Two more things worth putting in front of counsel:**

- **The upstream model providers' terms.** OpenRouter and the providers behind
  it (Google, Anthropic, Moonshot, Alibaba, DeepSeek) each set their own
  minimum-age terms, typically 13 or 18, and some of those terms make the app
  operator responsible for its users' eligibility. Whether routing a child's
  text through them is permitted at all is a contract question before it is a
  COPPA question. **UNKNOWN:** not checked as part of this work.
- **The App Store age rating and category.** Scoranger is not in the Kids
  Category today, and putting it there would bring guideline 1.3's much
  stricter rules (no third-party analytics or advertising, and parental gates
  on outbound links and purchases). The age rating Ali selects interacts with
  all of the above. **UNKNOWN:** no age rating is recorded in this repository.

**The honest shape of the problem, without answering it:** the signed-out path
is close to clean, because it collects no identity. The two things that survive
signing out are the chat and dictation, and both send a child's own words to a
third party. The signed-in path collects a child's email address and name and
writes the address into a server log that account deletion does not reach. That
last item is the sharpest edge.

---

## 10. Licence gaps to settle at submission time, not after

These are already in `BACKLOG.md` ("Found while building 0.9.0: two licence
texts that do not ship"). They are pointed at from here so they are not lost in
the submission scramble. **None of them is fixed by this work.**

1. **Eleven or twelve Python packages ship without their licence text.**
   `ios/scripts/vendor_engine.sh:79` runs `rm -rf "$PKGS"/*.dist-info`, and each
   package's `LICENSE` file goes with the directory. BACKLOG names: music21
   (BSD-3-Clause), pypdf (BSD-3-Clause), requests (Apache-2.0), urllib3 (MIT),
   certifi (MPL-2.0), idna (BSD-3-Clause), chardet (0BSD),
   charset-normalizer (MIT), joblib (BSD-3-Clause), jsonpickle (BSD-3-Clause),
   more-itertools (MIT), webcolors (BSD-3-Clause). BSD-3, MIT, Apache-2.0 and
   MPL-2.0 all require the notice to travel with a binary distribution.
   *Note: BACKLOG's prose says "Eleven packages" and then names twelve. Worth
   correcting when the fix lands.*
   The fix is to keep each `dist-info/LICENSE*` rather than the whole
   `dist-info`, and show them on the "How Scoranger works" screen.

2. **Six C libraries inside BeeWare's Python build ship with no licence file
   anywhere in the tree.** `ios/Vendor/VERSIONS` declares OpenSSL 3.5.7,
   XZ 5.6.4, Zstandard 1.5.7, bzip2 1.0.8, libFFI 3.4.7 and mpdecimal 4.0.0,
   and `Scoranger.app/Frameworks/` confirms every one ships. The only licence
   file under `ios/Vendor/Python.xcframework` is CPython's own. 0.9.0 names
   them on the credits screen with no SPDX identifier deliberately, because a
   guessed identifier is worse than an honest gap. The texts need sourcing
   upstream.

3. **Verovio is statically linked under LGPL-3.0.** `ios/project.yml:11-12,
   73-74` builds it as a local SPM package, so `VerovioToolkit` links into the
   app binary. Static linking under LGPL-3.0 requires either object files or an
   equivalent relinking mechanism for the user, or compliance by another route
   in §4/§6 of the licence. Not addressed.

4. **The sound bank has a bespoke licence with a sample-provenance
   disclaimer.** GeneralUser GS by S. Christian Collins, credited under
   "GeneralUser GS License v2.0" (`ScoreModel/Pipeline.swift:281-284`). The
   only licence text file in the entire `ios/` tree is
   `ios/PythonApp/app_packages/music21/scale/scala/scl/license.txt`, so the
   sound bank's own licence text does not ship either. Its provenance
   disclaimer about sample sources is the part that deserves reading before a
   commercial release.

Also recorded in BACKLOG and **not** a problem: `samples-seed` holds two
copyrighted editions in Debug builds only; `project.yml`'s fixture-baking phase
removes it for every other configuration and `check_no_bundled_scores.py` is
the release gate.

---

## 11. Everything marked UNKNOWN, in one place

| # | Unknown | Why | Who resolves it |
|---|---|---|---|
| 1 | ~~Google Cloud Logging retention for the OMR usage records~~ | **RESOLVED 2026-09-22: 30 days.** Project `scoranger-omr`, bucket `_Default`, no custom sinks or routers (`_Required` is Google's fixed 400 days and holds admin activity, not app logs). Read with `gcloud logging buckets list`. | The policy now says 30 days. |
| 2 | ~~Whether logging and training are disabled on the OpenRouter account~~ | **RESOLVED 2026-09-22: both off**, confirmed by Ali in the OpenRouter dashboard. | The policy now states it. |
| 3 | Which upstream provider serves a given chat request | OpenRouter routes at call time; no provider block is sent | Not resolvable in code. State it as "may vary" in the policy. |
| 4 | ~~The GCP project ID for the Cloud Run deployment~~ | **RESOLVED 2026-09-22: `scoranger-omr`**, service `scoranger-omr`, region `us-central1`. | -- |
| 5 | ~~Whether `FIREBASE_PROJECT_ID` is set on the live Cloud Run revision~~ | **RESOLVED 2026-09-22: it was NOT set** -- the only env var was `OMR_API_KEY`. So the live service could not verify tokens and every job logged unattributed. Set at the 0.13.0 OMR deploy (`--update-env-vars`, which merges), with the code that never logs an email. | -- |
| 6 | Runtime network behaviour of each linked SDK | No traffic capture was performed; linkage and SDK manifests only | A proxy capture, if ever needed |
| 7 | ~~Whether the shipped release archive contains a baked OpenRouter key~~ | **RESOLVED 2026-09-22: YES**, through build 203 (0.14.0) -- 73 bytes, readable by anyone who unzips the .ipa. **FIXED in 0.15.0 by removing it: chat brings its own key** (Ali, 2026-09-23), and the deploy refuses an archive that carries one. The retired key must still be REVOKED at OpenRouter, which is Ali's. The OMR key is still baked, capped at one server instance. | -- |
| 8 | Minimum-age terms of OpenRouter and the upstream model providers | Not checked | Counsel, with §9 |
| 9 | Scoranger's App Store age rating and whether it will be in the Kids Category | Nothing in this repository records it | Ali, with §9 |

---

## 12. Order of operations for submission

1. Resolve unknowns 1 and 2. The privacy policy cannot be truthful without them.
2. Make the six decisions in section 8.
3. Merge `feat/account-deletion` into the release branch. Guideline 5.1.1(v).
4. Add the app-level `PrivacyInfo.xcprivacy` (section 7). Expect ITMS-91053
   otherwise.
5. Host `design/privacy-policy.md` and `design/support.md` somewhere live and
   reachable. Put a real email address in the support page first.
6. Fill in the App Privacy questionnaire from section 5, by hand, in the
   browser.
7. Take the licence gaps in section 10 to a decision. They do not block
   submission; they do become harder once the app is public.
8. Take section 9 to a lawyer.
