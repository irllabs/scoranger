# Search: tunes by name from thesession.org and MuseScore (0.20.0)

Ali, 2026-10-12: "look up a song by name and find its score either in
MuseScore or in thesession.org ... another option under import for search
... the user can check boxes select where they're searching ... in the case
of MuseScore I wanna support login because I myself am a member."

## 1. What each site allows, verified 2026-10-12

**thesession.org** answers every page in JSON when `format=json` is
appended: `/tunes/search?q=…` (10 hits a page, with `pages` and `total`;
both absent when nothing matched) and `/tunes/N` (name, type, aliases, every
setting with its key, contributor and ABC body). `/tunes/N/abc` is the ABC
of every setting as the site writes it, with `M:`, `L:`, `R:` and an `S:`
line naming each setting's page. There is no per-setting download.
`robots.txt` asks for a 10-second crawl delay. The site's own terms page
refuses anything that is not a browser, so they are unread; the maintainer's
data dump on GitHub is share-and-adapt with a ban on LLM processing
(BACKLOG: what that means for chat).

**musescore.com** has no API: the one at `api.musescore.com` was shut down
for abuse, and no developer programme has replaced it. Terms (2025-09-27):
content is for personal, non-commercial use; no "automated systems (except
for those that may be provided by MuseScore) for accessing or downloading
Content"; a member may not let another person use their IDs; PRO and PRO+
download 20 scores a day, 300 a month; "official" scores never. The search
page and the terms page serve a Cloudflare challenge to anything but a
browser. Apple's guideline 5.2.2 requires that use of a third-party service
be "specifically permitted" under its terms, "upon request".

## 2. The screen

Import gains a fifth row, **Search**, after Book: the four above bring in
something the reader has; this finds one.

The Search page: one field with a Search button (one request per press,
never per keystroke), a tick box per source with one line saying what it
finds and how, remembered under `searchSources`. Results sit in bands under
a rule, one per ticked source, MuseScore's first because it is one row.

**thesession.org's band**: the count ("51 tunes"), one row per hit with the
type and the alias the search matched, More while there are pages. A hit
opens to the tune: name, type, aliases, a sentence saying what a setting is,
**Import all N**, a link to the page, and one row per setting ("Setting 3 ·
G major", "by Jeremy") with its own **Import** that becomes **Open**.

**MuseScore's band**: one row, "Search MuseScore for “…”", which opens the
site's own search for those words in a web view inside Scoranger. The
reader signs in there once; the web view keeps the session and the app
never sees the password. The site's own Download button, MusicXML chosen,
lands the file in the library through the one import path, with the page
as origin, and the score opens. MSCZ is refused by name with the fix.

## 3. How a tune imports

`/tunes/N/abc` is fetched once a session and cut down in Swift to the
settings chosen (`ABCSettings.select`: keep the `X:` blocks whose `S:` ends
`#setting<id>`, renumber `X:`), written to a temporary `.abc`, and imported
by the engine's ABC path -- the one proven over 540 of the site's tunes.
Nothing is reconstructed from the JSON. The tune's URL is `--origin` on the
version. The engine fetches nothing: it imports no network client
(check_signed_out.py), so the client is Swift (`TheSessionClient`), with a
`TuneFinder` protocol the tests answer from captured JSON.

## 4. Not in 0.20.0

- Ultimate Guitar: no API, Pro tabs are Guitar Pro files the engine cannot
  read, terms forbid storing downloads (BACKLOG).
- Google sign-in inside the web view (Google refuses embedded web views;
  email/password and Apple work -- unverified on a real account).
- Searching MuseScore from the app's own field.
- Other sources with open licences, later tick boxes: OpenScore (CC0
  MusicXML), Mutopia, IMSLP (PDF, through OMR), CPDL.
