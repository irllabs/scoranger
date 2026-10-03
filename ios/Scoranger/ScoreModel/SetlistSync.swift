import Foundation

/// What it takes to bring one shared set list's local row and its Firestore
/// entries into step, decided with no Firebase in hand.
///
/// Ali added a tune to "Echo and Bubba" on his iPad and it never reached
/// Echo. Both directions were missing: the row was filled from the server
/// once, at join, and adding to it from the library wrote only the local
/// document. This is the decision both directions need; `AppState` carries
/// it out.
///
/// It is a THREE-WAY merge, and the third side is `base`: the entries the
/// row held the last time this device brought it into step. Without it an
/// entry on the server that the row lacks could be one somebody else added
/// (adopt it) or one this reader removed (take it off the server), and the
/// two are opposite acts.
enum SetlistSync {

    /// One entry as the server holds it.
    struct Remote: Equatable {
        let id: String
        /// The fractional index (`SharedOrder`); sorting on it is the order.
        let order: String
        let scoreUid: String
        let isRemoved: Bool
    }

    /// One arrangement in the local row, with what can tie it to an entry.
    struct Local: Equatable {
        let slug: String
        /// The arrangement's own uid: what an entry this account pushed names.
        let uid: String?
        /// The entry this arrangement is a copy of, when it was adopted.
        let sharedEntry: String?
    }

    /// One place in the running order the row should end with.
    enum Item: Equatable {
        /// An arrangement already in the row.
        case local(String)
        /// An entry this device has to adopt first.
        case adopt(String)
    }

    struct Plan: Equatable {
        /// Entries somebody else added, to import and file, in server order.
        var adopt: [String] = []
        /// Arrangements this reader added, to upload as new entries, in row
        /// order. Each lands after the last entry on the server.
        var push: [String] = []
        /// Entries this reader took out of the row, to soft-remove.
        var withdraw: [String] = []
        /// Arrangements to take out of the row: their entry was removed.
        var dropLocally: [String] = []
        /// The order key for each of `push`, after everything on the server.
        var pushKeys: [String] = []
        /// New order keys for entries, when the row was reordered here.
        var moves: [String: String] = [:]
        /// The running order the row ends with. Pushed arrangements follow it.
        var order: [Item] = []

        /// Nothing to write to the server.
        var writesNothing: Bool { push.isEmpty && withdraw.isEmpty && moves.isEmpty }
        /// Nothing to change in the row.
        var changesNothingHere: Bool { adopt.isEmpty && dropLocally.isEmpty }
    }

    /// Which entry each arrangement in the row is, if any.
    ///
    /// A live entry beats a removed one, so an arrangement removed by somebody
    /// and added again here maps to its new entry rather than the old one.
    /// `copies` is this device's own record of what it adopted
    /// (`SharedEntryCopies`), for copies made before the link was kept on the
    /// arrangement itself.
    static func links(local: [Local], remote: [Remote],
                      copies: [String: String]) -> [String: String] {
        var bySlug: [String: String] = [:]
        let byCopy = Dictionary(copies.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        for item in local {
            let candidates = remote.filter { entry in
                entry.id == item.sharedEntry
                    || (item.uid != nil && entry.scoreUid == item.uid)
                    || byCopy[item.slug] == entry.id
            }
            let pick = candidates.filter { !$0.isRemoved }.min { $0.order < $1.order }
                ?? candidates.first
            if let pick { bySlug[item.slug] = pick.id }
        }
        return bySlug
    }

    /// The plan.
    ///
    /// - `local`: the row, in its running order.
    /// - `remote`: every entry, removed ones included -- a removal is news.
    /// - `base`: the entry ids the row held when last in step, in order; nil
    ///   when this device has never brought it into step. With no base nothing
    ///   can be read as a removal made here, so nothing is withdrawn: the first
    ///   sync only adds, in both directions.
    /// - `mayEdit`: false for a reader, who changes nothing on the server.
    static func plan(local: [Local], remote: [Remote], base: [String]?,
                     copies: [String: String] = [:], mayEdit: Bool) -> Plan {
        var plan = Plan()
        let link = links(local: local, remote: remote, copies: copies)
        let entry = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = remote.filter { !$0.isRemoved }.sorted { $0.order < $1.order }
        let baseSet = Set(base ?? [])
        let linkedEntries = Set(link.values)

        // The row, arrangement by arrangement.
        var kept: [Local] = []
        for item in local {
            guard let id = link[item.slug], let found = entry[id] else {
                // No entry at all: added here.
                if mayEdit { plan.push.append(item.slug) }
                kept.append(item)
                continue
            }
            if found.isRemoved {
                // Removed on the server. If the row held it when last in
                // step, somebody removed it since and the row follows. If it
                // did not, it was added here after the removal: a new entry.
                if base == nil || baseSet.contains(id) {
                    plan.dropLocally.append(item.slug)
                } else {
                    if mayEdit { plan.push.append(item.slug) }
                    kept.append(item)
                }
                continue
            }
            kept.append(item)
        }

        // The server, entry by entry.
        var adopting: Set<String> = []
        let rowUids = Set(kept.compactMap { item in link[item.slug] != nil ? item.uid : nil })
        for found in live where !linkedEntries.contains(found.id) {
            if rowUids.contains(found.scoreUid) {
                // A second entry for an arrangement the row already holds by
                // another entry: two pushes of one add. Adopting it would
                // import a copy of the reader's own arrangement beside it.
                if mayEdit { plan.withdraw.append(found.id) }
                continue
            }
            if base != nil, baseSet.contains(found.id), mayEdit {
                plan.withdraw.append(found.id)     // taken out here
            } else {
                plan.adopt.append(found.id)        // added elsewhere
                adopting.insert(found.id)
            }
        }

        // The order. The row's own, when it was reordered here since the last
        // sync; otherwise the server's.
        var seen: Set<String> = []
        let keptLinked = kept.compactMap { item -> String? in
            guard let id = link[item.slug], entry[id]?.isRemoved == false,
                  seen.insert(id).inserted else { return nil }
            return id
        }
        let reorderedHere: Bool = {
            guard mayEdit, let base else { return false }
            let common = Set(keptLinked).intersection(baseSet)
            let mine = keptLinked.filter(common.contains)
            let then = base.filter(common.contains)
            return mine != then
        }()
        // The first arrangement in the row to claim an entry is the one that
        // stays, so which copy survives a duplicate does not depend on the
        // order a dictionary happens to iterate in.
        var slugFor: [String: String] = [:]
        for item in kept {
            if let id = link[item.slug], slugFor[id] == nil { slugFor[id] = item.slug }
        }
        let pushed = Set(plan.push)

        if reorderedHere {
            // The row's order, with adopted entries after it in server order,
            // and a key for every entry whose place changed.
            var ids = keptLinked
            ids.append(contentsOf: plan.adopt)
            plan.order = keptLinked.compactMap { slugFor[$0].map(Item.local) }
                + plan.adopt.map(Item.adopt)
            let current = ids.compactMap { entry[$0]?.order }
            if current != current.sorted() || Set(current).count != current.count {
                let keys = SharedOrder.spread(count: ids.count)
                for (id, key) in zip(ids, keys) where entry[id]?.order != key {
                    plan.moves[id] = key
                }
            }
        } else {
            let withdrawn = Set(plan.withdraw)
            plan.order = live.compactMap { found in
                if withdrawn.contains(found.id) { return nil }
                if adopting.contains(found.id) { return .adopt(found.id) }
                return slugFor[found.id].map(Item.local)
            }
        }
        // Arrangements added here follow, in the row's order -- and so does
        // any a reader added, who cannot push them but whose row keeps them.
        let placed = Set(plan.order.compactMap { item -> String? in
            if case .local(let slug) = item { return slug }
            return nil
        })
        for item in kept where !placed.contains(item.slug)
            && (pushed.contains(item.slug) || link[item.slug] == nil) {
            plan.order.append(.local(item.slug))
        }
        // A second copy of an entry already in the row (two adoptions of one
        // entry) is the one thing left over: it leaves the row, as a removal
        // here would, and the arrangement itself stays in the library.
        let ordered = Set(plan.order.compactMap { item -> String? in
            if case .local(let slug) = item { return slug }
            return nil
        })
        for item in kept where !ordered.contains(item.slug) {
            plan.dropLocally.append(item.slug)
        }
        let withdrawn = Set(plan.withdraw)
        let keys = live.filter { !withdrawn.contains($0.id) }
            .map { plan.moves[$0.id] ?? $0.order }
        plan.pushKeys = appendKeys(after: keys.max(), count: plan.push.count)
        return plan
    }

    /// Keys for entries pushed after everything on the server, in order.
    static func appendKeys(after last: String?, count: Int) -> [String] {
        var keys: [String] = []
        var previous = last
        for _ in 0..<count {
            let key = SharedOrder.between(previous, nil)
            keys.append(key)
            previous = key
        }
        return keys
    }

    /// How a shared row stands, for the button beside its share button.
    enum Status: Equatable {
        /// Matches the server as of the last sync.
        case inStep
        /// A sync is running.
        case syncing
        /// The last sync failed; the reason is what to show.
        case trouble(String)
        /// Not yet brought into step on this device.
        case unknown

        var symbol: String {
            switch self {
            case .inStep:   return "checkmark.icloud"
            case .syncing:  return "arrow.triangle.2.circlepath.icloud"
            case .trouble:  return "exclamationmark.icloud"
            case .unknown:  return "icloud"
            }
        }

        func label(for title: String) -> String {
            switch self {
            case .inStep:             return "Sync \(title). In step."
            case .syncing:            return "Syncing \(title)"
            case .trouble(let why):   return "Sync \(title). Last sync failed: \(why)"
            case .unknown:            return "Sync \(title)"
            }
        }
    }
}
