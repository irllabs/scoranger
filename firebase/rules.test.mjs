// The security rules, exercised against the emulator.
//
// These rules are the ONLY enforcement of the sharing model.
// ios/Scoranger/ScoreModel/SetlistPermission.swift is the client's opinion of
// the same thing and a modified client ignores it, so every claim the app makes
// about who may do what has to be asserted here too.
//
// Run: cd firebase && npm test
import { readFileSync } from 'node:fs';
import {
  initializeTestEnvironment, assertFails, assertSucceeds,
} from '@firebase/rules-unit-testing';
import {
  doc, getDoc, setDoc, updateDoc, deleteDoc, collection, getDocs,
  query, where, orderBy, limit, writeBatch, serverTimestamp, Timestamp,
} from 'firebase/firestore';
import { ref, getBytes, uploadBytes } from 'firebase/storage';

const env = await initializeTestEnvironment({
  projectId: 'scoranger-rules-test',
  firestore: { rules: readFileSync('firestore.rules', 'utf8') },
  storage: { rules: readFileSync('storage.rules', 'utf8') },
});

const OWNER = 'u-ali';
const MEMBER = 'u-son';
const READER = 'u-dep';
const STRANGER = 'u-nobody';
const SET = 'set-friday';
const ENTRY = 'entry-1';

function as(uid, claims = {}) {
  return env.authenticatedContext(uid, claims);
}
const anon = () => env.unauthenticatedContext();

// The world every test starts in: one setlist, one entry, three people.
async function seed() {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'setlists', SET), {
      name: 'Friday',
      ownerId: OWNER,
      members: { [OWNER]: 'owner', [MEMBER]: 'member', [READER]: 'reader' },
      memberIds: [OWNER, MEMBER, READER],
    });
    await setDoc(doc(db, 'setlists', SET, 'entries', ENTRY), {
      title: "Morrison's Jig", order: 'i', addedBy: OWNER, mode: 'copy',
    });
    await setDoc(doc(db, 'setlists', SET, 'entries', ENTRY, 'ink', MEMBER), {
      layer: 'personal', pages: {},
    });
    await setDoc(doc(db, 'libraries', 'lib-ali'), { owner: OWNER, name: "Ali's" });
    await setDoc(doc(db, 'memberships', `${MEMBER}_${SET}`), {
      userId: MEMBER, setlistId: SET, role: 'member',
    });
    await setDoc(doc(db, 'invites', 'inv-1'), {
      setlistId: SET, setlistName: 'Friday', emailLower: 'son@example.com',
      invitedBy: OWNER, invitedAt: 'now',
    });
    const bucket = ctx.storage();
    await uploadBytes(ref(bucket, `shared/${SET}/${ENTRY}/v1.musicxml.gz`), new Uint8Array([1, 2]));
    await uploadBytes(ref(bucket, 'libraries/lib-ali/scores/s1/v1.musicxml.gz'), new Uint8Array([3]));
  });
}

const results = [];
async function check(name, promise) {
  try { await promise; results.push(['ok', name]); }
  catch (e) { results.push(['FAIL', `${name} -- ${e.message?.slice(0, 140)}`]); }
}

await env.clearFirestore();
await seed();

// ---- who can see a shared setlist at all -----------------------------------
await check('signed out cannot read a shared setlist',
  assertFails(getDoc(doc(anon().firestore(), 'setlists', SET))));
await check('a stranger cannot read a shared setlist',
  assertFails(getDoc(doc(as(STRANGER).firestore(), 'setlists', SET))));
await check('a member can read it',
  assertSucceeds(getDoc(doc(as(MEMBER).firestore(), 'setlists', SET))));
await check('a stranger cannot read its entries',
  assertFails(getDocs(collection(as(STRANGER).firestore(), 'setlists', SET, 'entries'))));
await check('a member can read its entries',
  assertSucceeds(getDocs(collection(as(MEMBER).firestore(), 'setlists', SET, 'entries'))));
await check('listing all setlists is refused even for a member',
  assertFails(getDocs(collection(as(MEMBER).firestore(), 'setlists'))));

// ---- principle 4: every member edits, only the owner deletes ---------------
await check('a member can add an entry',
  assertSucceeds(setDoc(doc(as(MEMBER).firestore(), 'setlists', SET, 'entries', 'e-new'),
    { title: 'The Kesh', order: 'm', addedBy: MEMBER, mode: 'copy' })));
await check('a member can reorder an entry',
  assertSucceeds(updateDoc(doc(as(MEMBER).firestore(), 'setlists', SET, 'entries', ENTRY),
    { order: 'z' })));
await check('a MEMBER CANNOT DELETE THE SETLIST',
  assertFails(deleteDoc(doc(as(MEMBER).firestore(), 'setlists', SET))));
await check('a reader cannot add an entry',
  assertFails(setDoc(doc(as(READER).firestore(), 'setlists', SET, 'entries', 'e-r'),
    { title: 'x', order: 'a' })));
await check('a stranger cannot add an entry',
  assertFails(setDoc(doc(as(STRANGER).firestore(), 'setlists', SET, 'entries', 'e-s'),
    { title: 'x', order: 'a' })));

// ---- the membership map is not the client's to write -----------------------
await check('a member cannot make itself the owner',
  assertFails(updateDoc(doc(as(MEMBER).firestore(), 'setlists', SET),
    { ownerId: MEMBER })));
await check('a member cannot rewrite the membership map',
  assertFails(updateDoc(doc(as(MEMBER).firestore(), 'setlists', SET),
    { members: { [MEMBER]: 'owner' } })));
await check('a member cannot add somebody to memberIds',
  assertFails(updateDoc(doc(as(MEMBER).firestore(), 'setlists', SET),
    { memberIds: [OWNER, MEMBER, READER, STRANGER] })));
await check('a member can rename the setlist',
  assertSucceeds(updateDoc(doc(as(MEMBER).firestore(), 'setlists', SET),
    { name: 'Friday at the Lescar' })));

// ---- creating one ----------------------------------------------------------
await check('creating a setlist makes you its owner and only member',
  assertSucceeds(setDoc(doc(as(MEMBER).firestore(), 'setlists', 'set-new'),
    { name: 'Mine', ownerId: MEMBER, members: { [MEMBER]: 'owner' }, memberIds: [MEMBER] })));
await check('you cannot create a setlist owned by somebody else',
  assertFails(setDoc(doc(as(MEMBER).firestore(), 'setlists', 'set-fake'),
    { name: 'Theirs', ownerId: OWNER, members: { [OWNER]: 'owner' }, memberIds: [OWNER] })));
await check('you cannot create a setlist that already has a crowd in it',
  assertFails(setDoc(doc(as(MEMBER).firestore(), 'setlists', 'set-crowd'),
    { name: 'Crowd', ownerId: MEMBER,
      members: Object.fromEntries([[MEMBER, 'owner'], ...Array.from({ length: 20 },
        (_, i) => [`u-${i}`, 'member'])]),
      memberIds: [MEMBER] })));

// ---- principle 5: everyone annotates, nobody writes anybody else's ---------
await check('a member writes their own ink',
  assertSucceeds(setDoc(doc(as(MEMBER).firestore(), 'setlists', SET, 'entries', ENTRY, 'ink', MEMBER),
    { layer: 'personal', pages: { 1: 'x' } })));
await check("a member CANNOT write another member's ink",
  assertFails(setDoc(doc(as(MEMBER).firestore(), 'setlists', SET, 'entries', ENTRY, 'ink', OWNER),
    { layer: 'personal', pages: { 1: 'x' } })));
await check('a reader writes their own ink',
  assertSucceeds(setDoc(doc(as(READER).firestore(), 'setlists', SET, 'entries', ENTRY, 'ink', READER),
    { layer: 'personal', pages: {} })));
await check("a member can read everyone's ink",
  assertSucceeds(getDocs(collection(as(MEMBER).firestore(),
    'setlists', SET, 'entries', ENTRY, 'ink'))));
await check('a stranger cannot read anybody\'s ink',
  assertFails(getDocs(collection(as(STRANGER).firestore(),
    'setlists', SET, 'entries', ENTRY, 'ink'))));

// ---- a private library stays private --------------------------------------
await check('the owner reads their own library',
  assertSucceeds(getDoc(doc(as(OWNER).firestore(), 'libraries', 'lib-ali'))));
await check("a member of a shared setlist cannot read the owner's library",
  assertFails(getDoc(doc(as(MEMBER).firestore(), 'libraries', 'lib-ali'))));
await check('a stranger cannot read a library',
  assertFails(getDoc(doc(as(STRANGER).firestore(), 'libraries', 'lib-ali'))));

// ---- the flat index and the invitations ------------------------------------
await check('a person reads their own membership row',
  assertSucceeds(getDoc(doc(as(MEMBER).firestore(), 'memberships', `${MEMBER}_${SET}`))));
await check("a person cannot read somebody else's membership row",
  assertFails(getDoc(doc(as(STRANGER).firestore(), 'memberships', `${MEMBER}_${SET}`))));
await check('no client writes the membership index',
  assertFails(setDoc(doc(as(MEMBER).firestore(), 'memberships', `${MEMBER}_x`),
    { userId: MEMBER, setlistId: 'x', role: 'owner' })));

await check('the invitee reads their invitation, by verified address',
  assertSucceeds(getDoc(doc(
    as('u-new', { email: 'son@example.com', email_verified: true }).firestore(),
    'invites', 'inv-1'))));
await check('an UNVERIFIED address cannot read the invitation',
  assertFails(getDoc(doc(
    as('u-new', { email: 'son@example.com', email_verified: false }).firestore(),
    'invites', 'inv-1'))));
await check('a different address cannot read it',
  assertFails(getDoc(doc(
    as('u-other', { email: 'someone@example.com', email_verified: true }).firestore(),
    'invites', 'inv-1'))));
await check('a member can invite',
  assertSucceeds(setDoc(doc(as(MEMBER).firestore(), 'invites', 'inv-2'),
    { setlistId: SET, setlistName: 'Friday', emailLower: 'friend@example.com',
      invitedBy: MEMBER, invitedAt: 'now' })));
await check('an invitation cannot smuggle content and become a read grant',
  assertFails(setDoc(doc(as(MEMBER).firestore(), 'invites', 'inv-3'),
    { setlistId: SET, setlistName: 'Friday', emailLower: 'f@example.com',
      invitedBy: MEMBER, invitedAt: 'now', storagePath: `shared/${SET}/x.pdf` })));
await check('nobody accepts their own invitation client-side',
  assertFails(updateDoc(doc(
    as('u-new', { email: 'son@example.com', email_verified: true }).firestore(),
    'invites', 'inv-1'), { acceptedBy: 'u-new', acceptedAt: 'now' })));

// ---- the bytes -------------------------------------------------------------
await check('signed out cannot read a shared file',
  assertFails(getBytes(ref(anon().storage(), `shared/${SET}/${ENTRY}/v1.musicxml.gz`))));
await check('a stranger cannot read a shared file',
  assertFails(getBytes(ref(as(STRANGER).storage(), `shared/${SET}/${ENTRY}/v1.musicxml.gz`))));
await check('a member can read a shared file',
  assertSucceeds(getBytes(ref(as(MEMBER).storage(), `shared/${SET}/${ENTRY}/v1.musicxml.gz`))));
await check('a member can upload a shared file',
  assertSucceeds(uploadBytes(ref(as(MEMBER).storage(), `shared/${SET}/e-new/v1.musicxml.gz`),
    new Uint8Array([9]))));
await check('a reader can read but NOT upload',
  assertSucceeds(getBytes(ref(as(READER).storage(), `shared/${SET}/${ENTRY}/v1.musicxml.gz`))));
await check('a reader cannot upload',
  assertFails(uploadBytes(ref(as(READER).storage(), `shared/${SET}/e-r/v1.musicxml.gz`),
    new Uint8Array([9]))));
await check("the owner reads their own library's files",
  assertSucceeds(getBytes(ref(as(OWNER).storage(), 'libraries/lib-ali/scores/s1/v1.musicxml.gz'))));
await check("nobody else reads the owner's library files",
  assertFails(getBytes(ref(as(MEMBER).storage(), 'libraries/lib-ali/scores/s1/v1.musicxml.gz'))));
// ---- library sync, as LibrarySync.swift does it (0.16.0) -------------------
{
  const mine = as(OWNER).firestore();
  const theirs = as(STRANGER).firestore();
  await check('a signed-in user creates a library they own',
    assertSucceeds(setDoc(doc(mine, 'libraries', 'lib-new'), { owner: OWNER })));
  await check('and cannot create one owned by somebody else',
    assertFails(setDoc(doc(theirs, 'libraries', 'lib-forged'), { owner: OWNER })));
  await check("a user records their library on their own user document",
    assertSucceeds(setDoc(doc(mine, 'users', OWNER), { libraryId: 'lib-new' }, { merge: true })));
  await check("and not on somebody else's",
    assertFails(setDoc(doc(theirs, 'users', OWNER), { libraryId: 'lib-forged' }, { merge: true })));
  const record = { payload: '{"name":"Reel"}', deleted: false, device: 'ipad',
                   updatedAt: serverTimestamp() };
  await check('the owner writes a record into their library',
    assertSucceeds(setDoc(doc(mine, 'libraries', 'lib-ali', 'scores', 'u-reel'), record)));
  await check('the owner batch-writes records, as a push does',
    assertSucceeds((async () => {
      const batch = writeBatch(mine);
      batch.set(doc(mine, 'libraries', 'lib-ali', 'versions', 'v-1'), record);
      batch.set(doc(mine, 'libraries', 'lib-ali', 'pieces', 'p-1'), record);
      await batch.commit();
    })()));
  const since = query(collection(mine, 'libraries', 'lib-ali', 'scores'),
    where('updatedAt', '>', Timestamp.fromMillis(0)), orderBy('updatedAt'), limit(300));
  await check("the owner pulls what changed since a cursor, as a pull does",
    assertSucceeds(getDocs(since)));
  await check("a stranger cannot pull it",
    assertFails(getDocs(query(collection(theirs, 'libraries', 'lib-ali', 'scores'),
      where('updatedAt', '>', Timestamp.fromMillis(0)), orderBy('updatedAt'), limit(300)))));
  await check("a stranger cannot write into it",
    assertFails(setDoc(doc(theirs, 'libraries', 'lib-ali', 'scores', 'u-planted'), record)));
  await check("a stranger cannot tombstone it",
    assertFails(setDoc(doc(theirs, 'libraries', 'lib-ali', 'scores', 'u-reel'),
      { deleted: true, device: 'x', updatedAt: serverTimestamp(), payload: '{}' })));
  await check("the owner uploads a version's file",
    assertSucceeds(uploadBytes(ref(as(OWNER).storage(), 'libraries/lib-ali/files/versions/v-1.musicxml'),
      new Uint8Array([1]))));
  await check("and a book",
    assertSucceeds(uploadBytes(ref(as(OWNER).storage(), 'libraries/lib-ali/files/books/b-1.pdf'),
      new Uint8Array([2]))));
  await check("a stranger cannot upload into it",
    assertFails(uploadBytes(ref(as(STRANGER).storage(), 'libraries/lib-ali/files/books/b-2.pdf'),
      new Uint8Array([2]))));
  await check("or download from it",
    assertFails(getBytes(ref(as(STRANGER).storage(), 'libraries/lib-ali/files/versions/v-1.musicxml'))));
}
await check('no path outside those two is readable at all',
  assertFails(getBytes(ref(as(OWNER).storage(), 'anything/else.pdf'))));

await env.cleanup();

const failed = results.filter(([s]) => s === 'FAIL');
for (const [state, name] of results) console.log(`    ${state === 'ok' ? 'ok  ' : 'FAIL'} ${name}`);
console.log(`\nrules: ${results.length - failed.length} passed, ${failed.length} failed`);
process.exit(failed.length ? 1 : 0);
