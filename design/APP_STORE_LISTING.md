# App Store listing — Scoranger

*What App Store Connect holds for the first submission, entered through the API
on 2026-10-04 (version 0.18.1). Every field below is one the submission asks
for. Character limits are Apple's and are counted here.*

---

## Name (30 max)

`Scoranger` — 9

## Subtitle (30 max)

`Arrange music by asking` — 23

Alternatives, same limit:
- `Rewrite scores in plain words` — 29
- `Your score, your instruments` — 28

## Promotional text (170 max, editable without review)

`Bring in a score, say what you want, and it rewrites the notation. Share set lists with your band, and keep your library on every device you sign in on.` -- 150

## Description (4000 max)

Scoranger rewrites musical scores for the instruments you actually have.

Bring in a score and say what you want in plain words. "Keep the violins, turn the viola and cello into an accordion left hand, add chord symbols." It carries that out and hands you back real notation.

The arranging is done by music software, not by a language model writing notes. The chat works out what you asked for and then calls the operations that do the work, so what comes back is correct notation rather than a guess at it. Nothing is overwritten: every change makes a new version, labelled with what made it, and you can go back to any of them.

WHAT IT DOES

• Transpose by interval, or by scale degree so a harmony line stays in the key
• Merge staves, split a part into bass and chords, fit a line to an instrument's range and clef
• Add and edit chord symbols, guitar tab, chord diagrams and penny-whistle fingerings
• Repeats, voltas, rehearsal marks, dynamics, ornaments and articulations
• Lay out the page: bars per line, where a line ends, measure numbers, spacing
• Play the arrangement back with a click, and read from it with a moving cursor
• Mark up any page with the Apple Pencil
• Print, or export as MusicXML, MIDI or PDF

WHAT IT READS

MusicXML, MIDI and ABC come in as notation. ABC tunes from sites like thesession.org import as one arrangement per tune, ornaments included.

A PDF or a photograph of a page can be read and marked up as it is, or converted into editable notation. Conversion is automatic reading of printed music: good on clean engraved pages, weaker on handwriting and faint photocopies. What you get is a draft to correct, which is why the original stays beside it.

A PDF tunebook can stay one book with its tunes listed, or be split into one arrangement per tune. Scoranger proposes where each tune starts and what it is called, and you confirm before anything is saved.

SET LISTS, ALONE OR WITH YOUR BAND

Put arrangements in running order and play through them. Share a set list with the people you play with: anyone in it can add and reorder tunes, and the list stays up to date for everyone.

ON THE DEVICE

The engine runs on your device. Importing, arranging, engraving, playback, pencil marks and export all work with no network at all. Two things need one: the chat, and converting a scan into notation.

The chat runs on your own OpenRouter account: make a key at openrouter.ai and paste it in Settings. You choose the model, and you pay OpenRouter directly for what you use.

No account is required. Sign in with Apple or Google only to keep your library on all your devices, or to share a set list.

FOR WHOM

Composers, arrangers and working musicians who have a score in one shape and need it in another.

## Keywords (100 max, comma-separated, no spaces after commas)

`sheet music,score,arranger,transpose,musicxml,notation,abc,setlist,chords,tab,composer,midi,pdf` — 97

## Category

- Primary: **Music**
- Secondary: **Productivity**

## Age rating

Expected **4+**. Every content descriptor NONE. Not made for kids, no Kids
Category. See `design/CHILDRENS_PRIVACY_BRIEF.md` for the reasoning and for
the one question the chat raises.

## Content rights

Uses third-party content: see `design/APP_STORE_PRIVACY.md` §10 and the
attribution screen in Settings. The declaration itself is a single yes/no with
no upload.

## URLs

- Support: **https://batchku.github.io/scoranger-support/** (live)
- Privacy policy: **https://scoranger.web.app/privacy/** (live 2026-09-22; built by `firebase/build_hosting.sh` from `design/privacy-policy.md`)
- Marketing: none

## Screenshots

Uploaded 2026-10-04 through the API: five each at iPhone 6.5" (1284 x 2778,
iPhone 14 Plus simulator) and iPad 13" (2064 x 2752, iPad Pro 13-inch M5),
in this order: Amazing Grace with chords and guitar tab, Ode to Joy with
whistle fingerings, playback, set lists (one shared), the library.

Taken by `ScorangerUITests/StoreShots` on `-seedStoreLibrary`, which is
public-domain music only -- the test library is copyrighted and must never
appear in a store picture. Retake with TEST_RUNNER_SCORANGER_SHOT_DIR set.

## App Review Information

**Notes for the reviewer -- REQUIRED from 0.15.0.** Chat needs the reader's own
OpenRouter key, and a reviewer who cannot use the chat cannot test the app's
main feature. Give App Review a working key in the Notes field, with a spend
limit set on it at openrouter.ai, and say where it goes:

> Scoranger's chat uses the reader's own OpenRouter account. To test it, open
> Settings › Engine and paste this key into "OpenRouter API key": [key]. It has
> a spend limit. Everything else in the app works without it.

Revoke that key once the review is done. Sign-in is only needed for sharing a
set list; Sign in with Apple works without a demo account.

## What's New

Written per release, diffed from the previous build's commits — never from
memory of what was worked on. See the memory note on release notes.
