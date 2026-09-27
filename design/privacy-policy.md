# Scoranger privacy policy

*Source for the page at https://scoranger.web.app/privacy/ -- rendered by
`firebase/build_hosting.sh`, which refuses while any bracketed placeholder
remains. Every factual claim below is traceable to `design/APP_STORE_PRIVACY.md`.
Amended 2026-09-22 to the code in 0.13.0: the chat no longer sends earlier
prompts, dictation is on-device only, and the scan log carries no email
address. Log retention (30 days) and the OpenRouter settings (logging and
training off) were confirmed that day. Amended 2026-09-23 for 0.15.0: chat
runs on the reader's own OpenRouter account and the app ships no chat key.
Amended 2026-09-27 for 0.16.0: a signed-in account keeps a private copy of its
library for its other devices, deleted with the account.*

---

**Last updated: 27 September 2026**

Scoranger is made by IRL Labs LLC. This page says what Scoranger does with your
music and your information. It is short because Scoranger does very little with
either.

## The short version

Your music lives on your iPad. Scoranger arranges it there, on the device, with
no account and no server. Three things leave your iPad, and all three are
things you asked for:

1. **When you use the chat**, what you type and a description of your score go
   to a language model run by another company.
2. **When you tap "Make editable" on a scan**, that page goes to our server to
   be read.
3. **When you sign in**, a private copy of your library is kept in your
   account on Google's Firebase, so it is the same on every device you sign
   in on; and when you share a set list, that set list's music and the marks
   you make on it go there too.

If you never sign in, never use the chat and never convert a scan, nothing
about you or your music ever leaves the iPad. Signed out, Scoranger does not
contact our servers or Google's at all. Not once, not even to say hello.

Scoranger has no analytics. It does not count your taps, it does not know how
often you open it, and it does not report crashes to us. There is no
advertising, no tracking, and nothing is ever sold or shared with a data broker.

## The chat, and the part people are surprised by

Scoranger's chat is a language model, and **it is not ours**. It runs on **your
own OpenRouter account**: you make a key at openrouter.ai/keys and paste it in
Settings, and chat is billed to that account. Scoranger ships no key of its
own. The key is kept in your iPad's Keychain and sent only to OpenRouter.

When you send a chat message, your iPad sends it straight to OpenRouter, which
passes it to whichever model you have chosen in Settings. The default is
Google's Gemini. The other choices are models from Anthropic, Moonshot AI,
Alibaba and DeepSeek. OpenRouter decides which of that company's servers
actually handles the request.

**What goes with your message:**

- what you typed, exactly as you typed it;
- the title, composer and arranger of the arrangement you have open;
- the name of the piece and the names of your other arrangements of it;
- the structure of the score: the parts, their instruments, their clefs, how
  high and low each one goes, how many bars and how many notes;
- the key and time signatures;
- if you have selected something on the page, what you selected;
- the rest of that conversation, so the model can follow it;
- and, when the model looks up your arrangement's history, what made each
  earlier version -- the operation and its settings, such as "transpose up a
  tone" -- and nothing you typed.

**What does not go:** the notation itself. No MusicXML, no MEI, no PDF, no
image of a page, no audio, and none of your pencil marks. The model is told
about your score; it is never given it.

**Scoranger adds nothing that identifies you.** No name, no email address and
no device identifier is sent with a chat message. The request is made with your
own key, so OpenRouter knows it came from your account, as it would for
anything else you do there. **We never see your chat messages**: they go from
your iPad to OpenRouter, and nowhere near a server of ours.

Because the account is yours, **so are its privacy settings**: whether OpenRouter
keeps the text of your prompts, and whether it may send them to model companies
that train on them, are set at openrouter.ai/settings/privacy. We suggest
turning both off. The model company that answers may keep a request for a time
under its own policy; we do not control that, and their privacy policies
govern it, not this one.

**Dictation.** The microphone button in the chat turns what you say into text
on your iPad, using Apple's on-device speech recognition. **The audio never
leaves the device.** If your iPad cannot do that for the language it is set
to, the chat field says so and dictation does nothing, rather than sending your
voice anywhere. Once it is text, it goes wherever your typed messages go.

## Scanning a page

Scoranger can read a photograph or a PDF scan of printed music and turn it into
notation you can edit. That reading happens on our server, not on your iPad,
because the software that does it is too large to carry.

**Importing a scan sends nothing anywhere.** The page only leaves your iPad
when you tap **Make editable**.

When you do, your iPad uploads the page itself and nothing else. No file name,
no title, no device identifier. The server reads it and sends back the
notation. The uploaded page is held in temporary storage for up to an hour and
then deleted, and it is never written to any permanent store.

**If you are signed in, we log which account asked.** Every conversion writes
one line to our server log recording your account's identifier -- a random
string, not your name and **never your email address** -- how many pages, how
long it took and whether it worked. We do this to know what scanning costs us
per person, because it is the only part of Scoranger we pay for by the page.
If you are signed out, that line says "anonymous" and carries no identifier.

Be aware of two things about that log. First, when a page cannot be read, the
last part of the reader's own output is written to the log too, and that output
can contain words the reader recognised on your page. Second, **these lines
are kept for 30 days and then deleted.** Deleting your account does not remove
them sooner -- they live in a different system from your account -- but they
name an account only by that random string.

## An account, and sharing with your band

You never need an account. Sign in only if you want your library on more than
one device, or to share a set list with other people.

**Signing in.** You can use Sign in with Apple or a Google account. Firebase
Authentication, which is Google's, then holds your account identifier, your
email address and the name your provider supplied. If you use Apple's Hide My
Email, we get the relay address and keep it, because that is the address your
bandmates have to send an invitation to.

**Your library on your other devices.** While you are signed in, a copy of your
library is kept in your account on Google's Firebase: your arrangements and
every version of them, the sources you imported beside them, your pieces, your
set lists and your books, including the music files and the book files
themselves. That is what lets your iPhone show what you arranged on your iPad.
It is readable by your account and by nobody else, not even the people in your
shared set lists. A change you make on one device reaches the others; a
delete does too. Your pencil marks on your own library are not part of it yet:
they stay on the device where you drew them. Signing out stops the syncing and
leaves the library on the device; it does not delete anything.

**Sharing a set list.** When you share one, the following goes to Google's
Firebase:

- the set list's name, and who its members are, recorded as account identifiers
  and nothing more;
- for each arrangement in it: the title, the composer, the version label, its
  size and a checksum, and **a copy of the music file itself**;
- the pencil marks you draw on those pages, stored under your account
  identifier so the others can see whose marks are whose;
- when you invite somebody, **the email address you typed for them**, so the
  invitation can find them. Invitations expire after seven days.

**Two kinds of invitation.** When you share a set list, Scoranger gives you a
link to send. That link can be used by **anyone who has it and is signed in to
Scoranger with a confirmed email address**, up to the twelve-person limit, for
seven days, after which it stops working. You can also invite one specific
address, and that invitation can only be claimed by that address. Either way
the person has to have a Scoranger account: there is no way to read a shared
set list without one, and nothing in our storage is ever public.

**What is never shared.** Your own library is private to your account: it is
copied between your devices and to nobody else's. Books never share. Sources,
meaning other editions you have imported for reference, never share. Nothing
in a shared set list is readable by anyone outside it.

## What Scoranger does not do

- No analytics. Scoranger does not link Firebase Analytics, Google Analytics,
  or any measurement library. We do not know how many times you open it.
- No crash reporting to us. No Crashlytics, no third-party diagnostics.
- No advertising. No advertising identifier, no ad network, no tracking prompt.
- No tracking across apps or websites, and no sharing with data brokers, ever.
- No location. Scoranger contains no location code at all.
- No access to your contacts, your calendar, your health data or your photo
  library. When you pick a photo, iOS shows you the picker and hands us only
  the picture you chose. Scoranger never sees the rest.
- No purchases. There is nothing to buy inside the app.

## How long things are kept

| What | How long |
|---|---|
| Your library on the iPad | Until you delete it. It is yours and it is local. |
| The copy of your library kept for your other devices (signed in only) | Until you delete it: a delete on any of your devices removes it from the copy, and deleting your account removes the whole copy. |
| A page uploaded for scanning | Up to one hour in temporary storage, then deleted. |
| Scan log lines (an account identifier, never an email address) | 30 days, then deleted. |
| Your account, set lists, shared files and marks | Until you delete your account or leave the set list. |
| An invitation you sent | Seven days, then it expires. A used one is kept as a record of who joined. |
| Chat messages | We never receive them. What OpenRouter keeps is set by your own account's settings; what the model company keeps is theirs to say. |

## Deleting your account

**Settings → Account, under Careful → Delete my account.** It is in the app,
it takes two taps, and there is nobody to email.

What happens:

- Set lists you own **that other people are in** are handed on to the next
  person who joined. The band keeps its set list; you leave it.
- Set lists you own **that nobody else is in** are deleted outright, with their
  music files.
- Set lists you only belonged to carry on without you.
- **Your pencil marks are removed from every shared set list**, and nobody
  else's are touched.
- **The copy of your library kept for your other devices is deleted**, with
  every music file and book file in it.
- Your account record, your memberships and your profile are deleted.
- Your Apple sign-in token is revoked with Apple.
- Finally, your account itself is deleted from Firebase Authentication.

**The music on your iPad is not touched.** Deleting your account deletes the
account and the copy kept in it, not the library on the device in your hand.

Two things we keep, and we would rather tell you than not:

- **Invitations you sent to set lists that still exist** are switched off but
  not deleted, so the person who owns that set list keeps the record of who was
  invited and who used it. Those records still carry your old account
  identifier.
- **The scan log lines described above**, for up to 30 days. They carry your
  old account identifier and no email address, and they are deleted when the
  30 days are up.

## Children

Scoranger is not designed for children and is not in the App Store's Kids
category. It does not ask for anyone's age.

## Where things are stored

Accounts, the copy of your library kept for your other devices, set lists,
shared files and marks are held by Google Firebase.
Scanning runs on Google Cloud Run in the United States. Chat goes to OpenRouter
and on to the model company you selected, wherever they run. Using Scoranger's
account and sharing features means your data is processed in the United States.

## Changes

If this policy changes in a way that affects what leaves your iPad, the app
will say so. The date at the top is the last time it changed.

## Getting in touch

Questions about anything on this page, or a request about your data:

**batchku@gmail.com**

IRL Labs LLC
