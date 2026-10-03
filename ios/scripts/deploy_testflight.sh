#!/usr/bin/env bash
# Build, sign and upload a TestFlight build with no interaction.
#
#   ios/scripts/deploy_testflight.sh                # bump, archive, upload, wait
#   ios/scripts/deploy_testflight.sh --preflight    # check readiness, change nothing
#   ios/scripts/deploy_testflight.sh --no-bump      # reuse the current build number
#   ios/scripts/deploy_testflight.sh --no-wait      # don't block on processing
#
# Signing is manual and local: the identity and profile that bootstrap_signing.sh
# created. Nothing here needs an Apple ID session, an Xcode account or Apple's
# cloud-signing service -- the whole path is driven by the App Store Connect API
# key, which is what makes it runnable from a phone.
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=./lib/deploy_common.sh
source "scripts/lib/deploy_common.sh"

PREFLIGHT_ONLY=0
BUMP=1
WAIT=1
for arg in "$@"; do
  case "$arg" in
    --preflight) PREFLIGHT_ONLY=1 ;;
    --no-bump)   BUMP=0 ;;
    --no-wait)   WAIT=0 ;;
    -h|--help)   sed -n '2,10p' "$0"; exit 0 ;;
    *)           die "unknown argument: $arg" ;;
  esac
done

# ---------------------------------------------------------------- preflight
say "preflight"
require_tools xcodebuild xcodegen security openssl
load_deploy_env
PY=$(python_with_cryptography)

# gitignored build inputs that a fresh clone will not have
[[ -d "Vendor/Python.xcframework" ]] || die "Vendor/Python.xcframework missing -- run scripts/fetch_python.sh"
[[ -d "PythonApp/app_packages" ]]    || die "PythonApp/app_packages missing -- run scripts/vendor_engine.sh"
[[ -d "Licences/python" ]]           || die "Licences/python missing -- run scripts/vendor_engine.sh"

# The General MIDI bank. Gitignored and fetched, like the two above -- and a
# missing one is the SILENT failure of the set: the app builds, archives,
# uploads and plays, with every part on `AVAudioUnitSampler`'s own built-in
# near-sine and nothing anywhere saying the bank was not there. That shipped
# once. So the digest is checked and not only the path, because a truncated
# download is a file that exists.
BANK="Vendor/SoundFonts/GeneralUser-GS.sf2"
[[ -f "$BANK" ]] || die "$BANK missing -- run scripts/fetch_soundfont.sh"
BANK_SHA=$(awk -F\" '/^SHA256=/ {print $2; exit}' scripts/fetch_soundfont.sh)
[[ -n "$BANK_SHA" ]] || die "cannot read the bank digest from scripts/fetch_soundfont.sh"
[[ "$(shasum -a 256 "$BANK" | cut -d' ' -f1)" == "$BANK_SHA" ]] \
  || die "$BANK is not the pinned file -- run scripts/fetch_soundfont.sh"
[[ -f "Vendor/SoundFonts/LICENSE.txt" ]] \
  || die "Vendor/SoundFonts/LICENSE.txt missing -- somebody else's work ships in this binary; run scripts/fetch_soundfont.sh"
say "sound bank: $(du -h "$BANK" | cut -f1), digest ${BANK_SHA:0:12}"

# The vendored engine is gitignored and regenerated, and checking only that the
# directory EXISTS let a stale copy ship: `adjust_element` was written, tested
# and shipped in the engine while the app carried an ops.py without it, so the
# feature simply was not there on device and nothing said so.
#
# ONE implementation, and it is not this one. `check_vendored_engine.py`
# already derives the closure from what is actually vendored, compares every
# module byte for byte against the engine source, and asserts the closure is
# closed. Calling it beats a second copy of the same idea here.
#
# The second copy is why this is being written: the block that used to live
# here scraped the module list out of vendor_engine.sh with
#   sed -n 's/^for f in \(.*\); do$/\1/p'
# and vendor_engine.sh stopped having a `for f in ...` line the day it started
# DERIVING the closure instead of listing it. From then on the sed matched
# nothing, the preflight died with "cannot read the vendored module list", and
# no deploy could run at all -- found by deliberately staling a module to see
# whether the check would catch it, and getting the wrong error. Fail-closed,
# so nothing shipped stale; but a check that cannot read its own input is not
# a check, and this one was one edit away from being deleted in frustration
# rather than fixed.
VENDOR_CHECK="../engine/scripts/check_vendored_engine.py"
[[ -f "$VENDOR_CHECK" ]] || die "missing $VENDOR_CHECK"
VENDOR_PY="../engine/.venv/bin/python"
[[ -x "$VENDOR_PY" ]] || VENDOR_PY="$PY"
"$VENDOR_PY" "$VENDOR_CHECK" \
  || die "the vendored engine is stale or incomplete -- run scripts/vendor_engine.sh"

[[ -f "$SIGNING_PROFILE" ]] || die "no provisioning profile at $SIGNING_PROFILE -- run scripts/bootstrap_signing.sh"
[[ -f "$KEYCHAIN_PATH" ]]   || die "no signing keychain at $KEYCHAIN_PATH -- run scripts/bootstrap_signing.sh"

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
add_keychain_to_search_list
# Listed for this deploy only, and unlisted however it ends: see
# remove_keychain_from_search_list for what a listed, locked keychain did.
trap remove_keychain_from_search_list EXIT
IDENTITY=$(distribution_identity)
[[ -n "$IDENTITY" ]] || die "no distribution identity in $KEYCHAIN_PATH -- run scripts/bootstrap_signing.sh"

# a profile that expired mid-cycle produces a baffling codesign failure later
EXPIRY=$(security cms -D -i "$SIGNING_PROFILE" 2>/dev/null \
  | plutil -extract ExpirationDate raw - 2>/dev/null || echo "")
say "identity: $IDENTITY"
say "profile:  $PROFILE_NAME (expires ${EXPIRY:0:10})"

"$PY" scripts/lib/asc.py check >/dev/null \
  || die "the App Store Connect key cannot see its signing assets -- run scripts/lib/asc.py check"
say "App Store Connect key authenticates"

if [[ $PREFLIGHT_ONLY -eq 1 ]]; then
  say "preflight only: everything needed for a headless deploy is in place"
  exit 0
fi

# ------------------------------------------------------------- build number
if [[ $BUMP -eq 1 ]]; then
  say "bumping build number"
  scripts/bump_build.sh
else
  say "reusing the current build number"
  xcodegen generate >/dev/null
fi
BUILD_NUMBER=$(awk '/^ *CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "could not read the build number from project.yml"
say "building version $(awk '/^ *MARKETING_VERSION:/ {print $2; exit}' project.yml) build $BUILD_NUMBER"

# ------------------------------------------------------------------ archive
# Signing settings live in project.yml, scoped to this target's Release config:
# on the xcodebuild command line they would also apply to the Verovio SPM
# resource bundle, which cannot take a provisioning profile. codesign finds the
# key because bootstrap added the signing keychain to the search list.
say "archiving (this takes a few minutes)"
rm -rf "$ARCHIVE_PATH"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  | grep -E "error:|warning: (Provisioning|Signing)|ARCHIVE (SUCCEEDED|FAILED)" || true

[[ -d "$ARCHIVE_PATH" ]] || die "archive failed"

# THE ARCHIVE, not the build script. Checked here because this is the only
# moment the thing that will actually be uploaded exists: 0.6.20 build 180 went
# to TestFlight carrying four copyrighted score files while the build phase's
# own comment said it did not (design/FIREBASE.md §0.11). A gate on the source
# would have believed the comment.
"$VENDOR_PY" ../engine/scripts/check_no_bundled_scores.py "$ARCHIVE_PATH" \
  || die "the archive contains score files -- see design/FIREBASE.md §0.11"
ARCHIVED_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
  "$ARCHIVE_PATH/Products/Applications/$SCHEME.app/Info.plist")
[[ "$ARCHIVED_BUILD" == "$BUILD_NUMBER" ]] \
  || die "archive says build $ARCHIVED_BUILD but project.yml says $BUILD_NUMBER"
say "archived build $ARCHIVED_BUILD"

# A FIREBASE-LINKED BUILD WITH NO FIREBASE CONFIG MUST NOT SHIP.
#
# 0.7.1 build 184 did. It linked the SDK, found no GoogleService-Info.plist in
# the bundle, correctly disabled sign-in, and went out as a SHARING release
# whose sharing could not be reached -- Settings read "This build has no
# Firebase configuration, so signing in is unavailable."
#
# The build phase tolerates a missing plist ON PURPOSE and that is right: a
# checkout without secrets still has to build, and a signed-out app is a
# complete app. What was missing is that the tolerance is WRONG at the moment
# of shipping a build whose headline feature needs it. So the question is asked
# here, of the archive, and only when the SDK is actually linked -- a 0.6.x
# archive carries no Firebase and has to stay shippable.
APP_IN_ARCHIVE="$ARCHIVE_PATH/Products/Applications/$SCHEME.app"
if [[ -d "$APP_IN_ARCHIVE/Frameworks/FirebaseCore.framework" ]] \
   || grep -qa FirebaseApp "$APP_IN_ARCHIVE/$SCHEME" 2>/dev/null; then
  [[ -f "$APP_IN_ARCHIVE/GoogleService-Info.plist" ]] || die \
"this archive links Firebase but carries no GoogleService-Info.plist -- sign-in
       would be dead on the device. Put it at ios/GoogleService-Info.plist
       (scripts/link_worktree_inputs.sh links it into a worktree) and archive again"
  PROJ=$(/usr/libexec/PlistBuddy -c "Print :PROJECT_ID" \
         "$APP_IN_ARCHIVE/GoogleService-Info.plist" 2>/dev/null || true)
  [[ -n "$PROJ" ]] || die "the archived GoogleService-Info.plist has no PROJECT_ID"
  say "Firebase config in the archive: project $PROJ"

  # The reversed client id is what Google's callback returns through. With no
  # matching URL scheme the browser opens and never comes back, which reads as
  # a hang rather than as a misconfiguration.
  REV=$(/usr/libexec/PlistBuddy -c "Print :REVERSED_CLIENT_ID" \
        "$APP_IN_ARCHIVE/GoogleService-Info.plist" 2>/dev/null || true)
  if [[ -n "$REV" ]]; then
    /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" \
      "$APP_IN_ARCHIVE/Info.plist" 2>/dev/null | grep -q "$REV" || die \
"the archive does not register the reversed client id $REV -- Google sign-in
       would open a browser and never return"
    say "Google callback URL scheme registered"
  fi

  # Guideline 4.8: offering Google obliges an equivalent private option. And
  # concretely, the reader waiting on this has an Apple account and no Google
  # one, so Apple is not the secondary path here -- it is the only one.
  ENT=$(codesign -d --entitlements - --xml "$APP_IN_ARCHIVE" 2>/dev/null || true)
  grep -q "com.apple.developer.applesignin" <<<"$ENT" || die \
"this archive links Firebase but carries no Sign in with Apple entitlement"
  say "Sign in with Apple entitlement present"

  # The invitation is an https universal link, and without this entitlement in
  # the SIGNED app iOS never consults the association: the tap opens Safari and
  # the invitee never reaches the join screen. The AASA was live and correct
  # for days while the entitlements file simply did not name the domain, which
  # is the shape of every dead-on-arrival build so far -- the far half right
  # and the near half missing.
  grep -q "com.apple.developer.associated-domains" <<<"$ENT" || die \
"this archive links Firebase but carries no associated-domains entitlement --
       tapping an invitation link would open Safari instead of the app"
  grep -q "applinks:scoranger.web.app" <<<"$ENT" || die \
"the associated-domains entitlement does not name scoranger.web.app, which is
       the host the AASA is served from"
  say "Universal link entitlement present (applinks:scoranger.web.app)"

  # And the association itself, fetched. All four things Apple requires of it,
  # checked against the live host rather than against a file in the repo --
  # what matters is what the device will GET.
  AASA_HDR=$(curl -sS -o /tmp/scoranger-aasa.json \
    -w "%{http_code} %{content_type} %{num_redirects}" \
    "https://scoranger.web.app/.well-known/apple-app-site-association" || true)
  read -r AASA_CODE AASA_TYPE AASA_HOPS <<<"$AASA_HDR"
  [[ "$AASA_CODE" == "200" ]] || die "the AASA is not being served (HTTP $AASA_CODE)"
  [[ "$AASA_TYPE" == application/json* ]] || die \
"the AASA is served as $AASA_TYPE, and Apple requires application/json"
  [[ "$AASA_HOPS" == "0" ]] || die "the AASA redirects $AASA_HOPS times; Apple follows none"
  grep -q "V9DBGV72NL.com.irllabs.scoranger" /tmp/scoranger-aasa.json || die \
"the AASA does not name this app id"
  grep -q "/invite/" /tmp/scoranger-aasa.json || die \
"the AASA does not claim the /invite/ path"
  say "AASA live: 200, application/json, no redirect, /invite/* for this app id"

  # The Storage rule for shared/ reads the set list's members out of Firestore
  # (`firestore.get`). Live, that read runs as the Storage service agent, and
  # the agent needs roles/firebaserules.firestoreServiceAgent on the project or
  # the read fails, an evaluation error is a DENY, and the owner's own upload
  # comes back "User does not have permission" -- which is what build 187 did
  # in Ali's hands. The Firebase CLI grants the role when it deploys Storage
  # rules; ours went up by REST, so nothing did. The emulator does not need the
  # grant, so 44 green rules tests could not see it. Only the live project can
  # answer this, so the live project is asked.
  FB_PROJECT_NUMBER=$(gcloud projects describe "$PROJ" --format='value(projectNumber)' 2>/dev/null || true)
  if [[ -z "$FB_PROJECT_NUMBER" ]]; then
    die "cannot read the Firebase project's number with gcloud -- sign in (gcloud auth login) so the Storage rules' cross-service grant can be verified"
  fi
  STORAGE_AGENT="serviceAccount:service-${FB_PROJECT_NUMBER}@gcp-sa-firebasestorage.iam.gserviceaccount.com"
  gcloud projects get-iam-policy "$PROJ" --format=json 2>/dev/null \
    | python3 -c "
import json, sys
policy = json.load(sys.stdin)
agent, role = sys.argv[1], 'roles/firebaserules.firestoreServiceAgent'
ok = any(b['role'] == role and agent in b['members'] for b in policy['bindings'])
sys.exit(0 if ok else 1)
" "$STORAGE_AGENT" || die \
"the Storage service agent lacks roles/firebaserules.firestoreServiceAgent, so every
       upload to shared/ is refused -- grant it:
         gcloud projects add-iam-policy-binding $PROJ \\
           --member=$STORAGE_AGENT \\
           --role=roles/firebaserules.firestoreServiceAgent"
  say "Storage rules may read Firestore (firestoreServiceAgent granted)"

  # Every callable the app depends on must be at least as new as its source.
  # Build 187, in Ali's hands: the invite was minted open, and claimInvite
  # refused it as "sent to a different address" -- because the deployed
  # claimInvite was from the 8th and the open-link branch was written on the
  # 9th. Three of five functions had been redeployed; two had not. The emulator
  # suite runs the REPO's functions and so was green throughout; only the live
  # project can answer this, so the live project is asked: each function's
  # updateTime must be after the last commit that touched index.js.
  REPO_ROOT=$(git rev-parse --show-toplevel)
  FN_SOURCE_AT=$(git -C "$REPO_ROOT" log -1 --format=%cI -- firebase/functions/index.js)
  [[ -n "$FN_SOURCE_AT" ]] || die "cannot date firebase/functions/index.js from git"
  for fn in shareSetlist createInvite claimInvite revokeInvite removeMember; do
    DEPLOYED_AT=$(gcloud functions describe "$fn" --gen2 --region us-west1 \
                    --project "$PROJ" --format='value(updateTime)' 2>/dev/null || true)
    [[ -n "$DEPLOYED_AT" ]] || die "callable $fn is not deployed in $PROJ/us-west1"
    python3 - "$fn" "$DEPLOYED_AT" "$FN_SOURCE_AT" <<'PYCHK' || die \
"callable $fn was deployed before its source last changed -- redeploy the functions
       (firebase/functions/index.js changed $FN_SOURCE_AT, $fn deployed $DEPLOYED_AT)"
import sys
from datetime import datetime
fn, deployed, source = sys.argv[1:4]
parse = lambda t: datetime.fromisoformat(t.replace("Z", "+00:00"))
sys.exit(0 if parse(deployed) >= parse(source) else 1)
PYCHK
  done
  say "all five callables are newer than their source"
fi

# --------------------------------------------------- privacy manifests, sealed
#
# The ONE place this can be checked against a build that is actually going to
# Apple. Apple refused external distribution of 0.6.15 with ITMS-91061 for
# _hashlib.framework and _ssl.framework: OpenSSL is on the list of commonly
# used third-party SDKs, and every SDK on it must carry a PrivacyInfo.xcprivacy
# at its bundle root. Internal testing never noticed, because a warning only
# becomes a rejection at beta App Review, which is what external groups go
# through.
#
# Read off the BINARIES rather than from a list: any framework carrying OpenSSL
# symbols needs the file, so a payload upgrade that adds a third such module is
# caught here rather than by an email from Apple three days later.
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/$SCHEME.app"
MISSING_MANIFESTS=()
for framework in "$ARCHIVED_APP"/Frameworks/*.framework; do
  [[ -d "$framework" ]] || continue
  name=$(basename "$framework" .framework)
  binary="$framework/$name"
  [[ -f "$binary" ]] || continue
  if nm -a "$binary" 2>/dev/null \
       | grep -qE "BORINGSSL|openssl_grpc|OPENSSL_|EVP_[A-Za-z]"; then
    if [[ ! -f "$framework/PrivacyInfo.xcprivacy" ]]; then
      MISSING_MANIFESTS+=("$name")
    fi
  fi
done
if (( ${#MISSING_MANIFESTS[@]} )); then
  die "these archived frameworks link OpenSSL and carry no privacy manifest: ${MISSING_MANIFESTS[*]}.
     Apple will warn ITMS-91061 and refuse EXTERNAL TestFlight distribution.
     Add ios/PrivacyManifests/<module>.xcprivacy and rebuild -- the build seeds
     them into the payload and utils.sh signs them in
     (scripts/seed_privacy_manifests.sh)."
fi
say "privacy manifests present on every OpenSSL framework in the archive"

# And the APP's own, which is a different rejection with a different code.
# ITMS-91061 above is about SDKs on Apple's list; ITMS-91053, "Missing API
# declaration", is about REQUIRED-REASON APIs, and it is an automatic upload
# rejection rather than a warning. The app target had no manifest at all
# through 0.11.0 while nine of its files use UserDefaults. Checked against the
# archive because that is the bundle Apple receives, and checked for CONTENT
# rather than existence -- an empty manifest declares nothing and would pass a
# file-exists test.
APP_MANIFEST="$ARCHIVED_APP/PrivacyInfo.xcprivacy"
[[ -f "$APP_MANIFEST" ]] || die "the archived app has no PrivacyInfo.xcprivacy at its
     bundle root. Apple answers ITMS-91053 and REFUSES THE UPLOAD. The file is
     ios/Scoranger/PrivacyInfo.xcprivacy; if it is there, the resources build
     phase lost it -- re-run xcodegen generate."
/usr/libexec/PlistBuddy -c "Print :NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPIType" \
  "$APP_MANIFEST" > /dev/null 2>&1 || die "the archived app's PrivacyInfo.xcprivacy declares
     no required-reason API. It uses UserDefaults; an empty declaration is
     ITMS-91053 with extra steps. See engine/scripts/check_privacy_manifests.py."
say "the app's own privacy manifest is in the archive and declares its APIs"

# NO CHAT KEY SHIPS (0.15.0). Through 0.14.0 the developer's OpenRouter key was
# baked into the bundle as openrouter-default-key.txt, readable by anyone who
# unzipped the .ipa and usable from anywhere; chat now uses the reader's own
# key (Ali, 2026-09-23). project.yml deletes the file on every build, and this
# refuses an archive that somehow still carries one -- or any file whose
# contents look like an OpenRouter key -- because what matters is what Apple
# receives, not what the build step meant to do.
[[ ! -e "$ARCHIVED_APP/openrouter-default-key.txt" ]] || die "the archived app carries
     openrouter-default-key.txt -- a developer chat key would ship to every
     reader. Chat brings its own key; find what put it back."
if grep -rlE 'sk-or-v1-[0-9a-f]{20,}' "$ARCHIVED_APP" > /dev/null 2>&1; then
  die "a file in the archived app contains an OpenRouter key:
     $(grep -rlE 'sk-or-v1-[0-9a-f]{20,}' "$ARCHIVED_APP" | head -3 | sed "s|$ARCHIVED_APP/||")
     Chat brings its own key; nothing in the bundle may carry one."
fi
say "no OpenRouter key anywhere in the archive"

# EVERY LICENCE TEXT THE CREDITS SCREEN OFFERS IS IN THE ARCHIVE (0.15.0), and
# every Python package that ships has one. vendor_engine.sh deleted each
# package's .dist-info, LICENSE and all, until 0.15.0; BSD-3, MIT, Apache-2.0
# and MPL-2.0 require the notice to travel with the binary. The paths are read
# out of Pipeline.swift, the one list the screen itself draws from.
PIPELINE=Scoranger/ScoreModel/Pipeline.swift
texts=$(grep -oE 'text: "[^"]+"' "$PIPELINE" | sed -E 's/text: "(.*)"/\1/')
[[ -n "$texts" ]] || die "no credit in $PIPELINE points at a licence text -- the
     check below would pass on nothing"
while read -r text; do
  [[ -e "$ARCHIVED_APP/$text" ]] || die "the credits screen offers $text and the
     archived app does not carry it. Run scripts/vendor_engine.sh, or fix the
     credit's path in $PIPELINE."
done <<< "$texts"
for pkg in "$ARCHIVED_APP"/app_packages/*/; do
  name=$(basename "$pkg")
  [[ "$name" == __pycache__ ]] && continue
  [[ -n "$(ls -A "$ARCHIVED_APP/Licences/python/$name" 2>/dev/null)" ]] || die "app_packages/$name
     ships without its licence text in Licences/python/$name. Run scripts/vendor_engine.sh."
done
say "every licence text the credits offer is in the archive, one per Python package"

# Verovio's data/Liberation.css embeds Liberation Serif 1.04, which is GPLv2
# with a font exception, and the app never loads it. fetch_python.sh removes
# it; an older checkout, or a Verovio re-fetched by hand, would bring it back.
if find "$ARCHIVED_APP" -name Liberation.css | grep -q .; then
  die "the archived app carries Verovio's Liberation.css (Liberation Serif 1.04,
     GPLv2). Remove it: rm Vendor/verovio/data/Liberation.css, then archive again.
     See Licences/README.md."
fi
say "no GPLv2 font in the archive"

# ------------------------------------------------------- export and upload
say "exporting and uploading to TestFlight"
rm -rf "$EXPORT_DIR"
set +e
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath "$EXPORT_DIR" \
  -authenticationKeyPath "$ASC_KEY_FILE" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  > "build/export.log" 2>&1
EXPORT_STATUS=$?
set -e
if [[ $EXPORT_STATUS -ne 0 ]]; then
  grep -E "^error:" "build/export.log" | head -10 >&2 || true
  die "export/upload failed (exit $EXPORT_STATUS); full log at ios/build/export.log"
fi
say "upload accepted by App Store Connect"

# -------------------------------------------------------------------- wait
if [[ $WAIT -eq 1 ]]; then
  say "waiting for build $BUILD_NUMBER to finish processing"
  "$PY" scripts/lib/asc.py wait-build --version "$BUILD_NUMBER" \
    --bundle-identifier "$BUNDLE_ID" || \
    say "note: not VALID yet -- Apple's processing sometimes lags well past the upload"
fi

say "done: build $BUILD_NUMBER is on TestFlight"
