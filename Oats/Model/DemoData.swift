import Foundation

// Twelve interconnected sample meetings so the knowledge graph, action items and
// search have something real to chew on. Recurring people (Sarah, Marcus, Priya,
// Diego, Elena), projects (Apollo, Website redesign, Mobile app, Onboarding) and
// orgs (Acme, Northwind) run through them so the graph actually connects.
enum DemoData {
    struct Sample {
        let title: String
        let daysAgo: Int
        let duration: TimeInterval
        let summary: String
        let lines: [(Double, String, String)]   // (t, channel, text)
    }

    static var isLoaded: Bool {
        !(UserDefaults.standard.stringArray(forKey: demoKey) ?? []).isEmpty
    }

    private static let demoKey = "demoNoteIDs"

    @MainActor
    static func load(into store: NoteStore) {
        let now = Date()
        var ids: [String] = []
        for sample in samples {
            let created = store.createNote()
            let date = Calendar.current.date(byAdding: .day, value: -sample.daysAgo, to: now) ?? now
            let meta = NoteMeta(id: created.id, title: sample.title, createdAt: date,
                                duration: sample.duration, hasSummary: true, titleLocked: true)
            store.save(meta: meta)
            store.saveSummary(noteID: created.id, sample.summary)
            for line in sample.lines {
                store.appendSegment(noteID: created.id, TranscriptSegment(t: line.0, channel: line.1, text: line.2))
            }
            // Seed the extraction results too. The sample transcripts are a few
            // lines each, below the extractor's word floor, so scanning them
            // would honestly produce nothing; these curated items make the hub
            // and the graph alive the moment samples load.
            let actions = (sampleActions[sample.title] ?? []).map {
                ActionItem(text: $0.0, owner: $0.1, createdAt: date)
            }
            store.saveActions(noteID: created.id, actions)
            store.saveGraph(noteID: created.id, sampleGraphs[sample.title] ?? .empty)
            ids.append(created.id.uuidString)
        }
        var existing = UserDefaults.standard.stringArray(forKey: demoKey) ?? []
        existing.append(contentsOf: ids)
        UserDefaults.standard.set(existing, forKey: demoKey)
    }

    @MainActor
    static func remove(from store: NoteStore) {
        for raw in UserDefaults.standard.stringArray(forKey: demoKey) ?? [] {
            if let id = UUID(uuidString: raw) { store.deleteNote(id: id) }
        }
        UserDefaults.standard.removeObject(forKey: demoKey)
    }

    // Forget which notes were samples, without deleting them individually. Used
    // by the full reset, which wipes every note folder in one pass, so the demo
    // tracking must be cleared too or "Load samples" would think they're present.
    static func forgetTracking() {
        UserDefaults.standard.removeObject(forKey: demoKey)
    }

    // Prefs can track sample notes that no longer exist: migrated defaults from
    // an old install, or a notes folder deleted by hand. Left alone, that shows
    // a phantom "Remove samples" button and hides "Load samples" forever.
    @MainActor
    static func validateTracking(against store: NoteStore) {
        let tracked = Set(UserDefaults.standard.stringArray(forKey: demoKey) ?? [])
        guard !tracked.isEmpty else { return }
        let existing = Set(store.notes.map { $0.id.uuidString })
        if tracked.isDisjoint(with: existing) {
            UserDefaults.standard.removeObject(forKey: demoKey)
        }
    }

    static let samples: [Sample] = [
        Sample(title: "Apollo Kickoff", daysAgo: 21, duration: 2640, summary: """
        ## Overview
        Elena, Sarah and Marcus kicked off Apollo, Lumina's new flagship product, targeting a Q3 launch. Sarah owns the roadmap; Marcus leads engineering.
        ## Key points
        - Apollo's first release focuses on the analytics dashboard and the onboarding flow.
        - Marcus flagged that the backend needs a rewrite to hit the performance bar.
        - Elena wants Acme lined up as the design partner for Apollo.
        ## Action items
        - [ ] Sarah to publish the Apollo roadmap (Sarah)
        - [ ] Marcus to scope the backend rewrite (Marcus)
        - [ ] Elena to reach out to Acme about design-partnering Apollo (Elena)
        """, lines: [(2, "me", "Let's get Apollo moving, Q3 is the target."), (14, "them", "I'll own the roadmap. Marcus, you've got engineering?"), (28, "them", "Yes, but the backend needs a rewrite for performance.")]),

        Sample(title: "Website Redesign Sync", daysAgo: 19, duration: 1980, summary: """
        ## Overview
        Priya walked Sarah through the Website redesign direction. The new brand system supports the Apollo launch.
        ## Key points
        - Priya proposed a cleaner landing page centered on Apollo.
        - Sarah asked for a pricing page that matches the Q3 pricing.
        ## Action items
        - [ ] Priya to deliver landing page mockups (Priya)
        - [ ] Sarah to send Priya the final Apollo pricing (Sarah)
        """, lines: [(3, "them", "The redesign leads with Apollo."), (20, "me", "Great, make sure the pricing page matches Q3.")]),

        Sample(title: "Acme Customer Call", daysAgo: 18, duration: 2100, summary: """
        ## Overview
        Diego and Sarah met Acme, who have been at risk of churning. Acme is interested in Apollo as a design partner.
        ## Key points
        - Acme's main complaint is performance in the current product.
        - Diego positioned Apollo's rewrite as the fix; Acme agreed to pilot.
        ## Action items
        - [ ] Diego to send Acme the Apollo pilot agreement (Diego)
        - [ ] Sarah to schedule an Apollo demo for Acme (Sarah)
        """, lines: [(5, "me", "Acme, we know performance has been rough."), (30, "them", "If Apollo fixes that, we'll pilot it.")]),

        Sample(title: "Engineering Standup", daysAgo: 16, duration: 900, summary: """
        ## Overview
        Marcus and Priya synced on Apollo and the Mobile app. Performance work is the priority.
        ## Key points
        - Marcus started the Apollo backend rewrite; early numbers look good.
        - Priya needs the Mobile app design system before she can start screens.
        ## Action items
        - [ ] Marcus to share Apollo performance benchmarks (Marcus)
        - [ ] Priya to finish the Mobile app design system (Priya)
        """, lines: [(4, "them", "Apollo backend rewrite is underway."), (18, "them", "I need the design system for the Mobile app.")]),

        Sample(title: "Q3 Pricing Review", daysAgo: 15, duration: 1800, summary: """
        ## Overview
        Elena and Diego reviewed Q3 pricing for Apollo. The goal is to reduce churn while growing revenue.
        ## Key points
        - Proposed a usage-based tier for Apollo alongside the flat plan.
        - Diego worried the new pricing could confuse Acme mid-pilot.
        ## Action items
        - [ ] Elena to finalize Apollo pricing tiers (Elena)
        - [ ] Diego to brief Acme on pricing before the pilot (Diego)
        """, lines: [(6, "me", "Usage-based could grow revenue."), (22, "them", "Let's not confuse Acme mid-pilot.")]),

        Sample(title: "Hiring Sync", daysAgo: 14, duration: 1500, summary: """
        ## Overview
        Elena and Sarah reviewed hiring. They need a backend engineer for Apollo and a designer for the Mobile app.
        ## Key points
        - Tom is a strong backend candidate Marcus liked.
        - Aisha, a data engineer, could help with Apollo analytics.
        ## Action items
        - [ ] Sarah to schedule Tom's final interview (Sarah)
        - [ ] Elena to approve the Apollo headcount (Elena)
        """, lines: [(3, "me", "We need a backend hire for Apollo."), (16, "them", "Tom looked strong. Marcus agrees.")]),

        Sample(title: "Northwind Partnership", daysAgo: 12, duration: 2400, summary: """
        ## Overview
        Elena and Diego met Northwind about an integration partnership for Apollo.
        ## Key points
        - Northwind wants Apollo to integrate with their data platform.
        - Elena sees Northwind as a channel to reach customers like Acme.
        ## Action items
        - [ ] Diego to draft the Northwind integration scope (Diego)
        - [ ] Marcus to assess the Apollo API work for Northwind (Marcus)
        """, lines: [(5, "them", "Northwind wants an Apollo integration."), (25, "me", "That's a channel to more Acme-style customers.")]),

        Sample(title: "Onboarding Revamp", daysAgo: 10, duration: 1620, summary: """
        ## Overview
        Priya and Sarah worked on the Onboarding revamp to improve activation for Apollo.
        ## Key points
        - Current onboarding loses users before the first dashboard.
        - Priya proposed a guided setup tied to the Apollo analytics.
        ## Action items
        - [ ] Priya to prototype the guided onboarding (Priya)
        - [ ] Sarah to define the activation metric (Sarah)
        """, lines: [(4, "them", "We lose people before the first dashboard."), (19, "me", "Let's define what activation means.")]),

        Sample(title: "Mobile App Planning", daysAgo: 8, duration: 1980, summary: """
        ## Overview
        Marcus and Priya planned the Mobile app, a companion to Apollo.
        ## Key points
        - The Mobile app reuses the Apollo backend APIs.
        - Priya's design system is ready; screens start next week.
        ## Action items
        - [ ] Marcus to expose Apollo APIs for mobile (Marcus)
        - [ ] Priya to start the Mobile app screens (Priya)
        """, lines: [(3, "them", "Mobile reuses the Apollo APIs."), (17, "them", "Design system is ready, screens next week.")]),

        Sample(title: "Board Prep", daysAgo: 6, duration: 2700, summary: """
        ## Overview
        Elena and Sarah prepped the board deck. Apollo and the Acme pilot are the headline.
        ## Key points
        - Metrics: churn down, Apollo pilot with Acme, Northwind partnership in progress.
        - Elena wants to raise a Series B on the back of Apollo.
        ## Action items
        - [ ] Sarah to pull the churn and activation numbers (Sarah)
        - [ ] Elena to finalize the fundraising narrative (Elena)
        """, lines: [(6, "me", "Apollo and the Acme pilot lead the deck."), (28, "them", "And we tee up the Series B.")]),

        Sample(title: "Acme Renewal", daysAgo: 3, duration: 1740, summary: """
        ## Overview
        Diego, Sarah and Acme discussed Acme's renewal now that the Apollo pilot is going well.
        ## Key points
        - Acme is happy with Apollo's performance and wants to expand seats.
        - Pricing follows the new Q3 usage-based tier.
        ## Action items
        - [ ] Diego to send Acme the renewal on the usage-based tier (Diego)
        - [ ] Sarah to confirm Apollo seat limits with Marcus (Sarah)
        """, lines: [(4, "them", "Apollo's performance won us over, we want more seats."), (21, "me", "We'll renew you on the usage-based tier.")]),

        Sample(title: "Team Retro", daysAgo: 1, duration: 1500, summary: """
        ## Overview
        The whole team ran a retro on the Apollo push: Elena, Sarah, Marcus, Priya and Diego.
        ## Key points
        - Wins: Apollo rewrite landed, Acme renewed, Northwind moving.
        - Risks: Mobile app timeline is tight; hiring for Apollo still open.
        ## Action items
        - [ ] Sarah to rebalance the Mobile app timeline (Sarah)
        - [ ] Elena to close the Apollo backend hire (Elena)
        """, lines: [(5, "me", "Apollo rewrite landed and Acme renewed."), (24, "them", "Mobile timeline is tight though.")]),
    ]

    // MARK: - Curated extraction results

    // What the extractor would pull from each sample if the transcripts were
    // full length. Keyed by sample title.
    private static let sampleActions: [String: [(String, String?)]] = [
        "Apollo Kickoff": [("Write the Apollo project brief", "Sarah"),
                           ("Set up the weekly Apollo standup", "Marcus")],
        "Website Redesign Sync": [("Ship the new landing hero", "Priya"),
                                  ("Collect before and after conversion numbers", "Diego")],
        "Acme Customer Call": [("Send Acme the onboarding checklist", "Sarah"),
                               ("File the SSO bug Acme hit", "Marcus")],
        "Engineering Standup": [("Fix the flaky deploy pipeline", "Marcus")],
        "Q3 Pricing Review": [("Finalize Apollo pricing tiers", "Elena"),
                              ("Brief Acme on pricing before the pilot", "Diego")],
        "Hiring Sync": [("Post the backend engineer role", "Elena"),
                        ("Schedule onsites for the two finalists", "Sarah")],
        "Northwind Partnership": [("Draft the Northwind co-marketing one-pager", "Diego"),
                                  ("Loop legal in on the data-sharing terms", "Elena")],
        "Onboarding Revamp": [("Prototype the guided onboarding", "Priya"),
                              ("Define the activation metric", "Sarah")],
        "Mobile App Planning": [("Expose Apollo APIs for mobile", "Marcus"),
                                ("Start the mobile app screens", "Priya")],
        "Board Prep": [("Pull the churn and activation numbers", "Sarah"),
                       ("Finalize the fundraising narrative", "Elena")],
        "Acme Renewal": [("Confirm Apollo seat limits with Marcus", "Sarah"),
                         ("Send the renewal quote to Acme", "Diego")],
        "Team Retro": [("Close the Apollo backend hire", "Elena"),
                       ("Trim the standup to fifteen minutes", "Marcus")],
    ]

    private static func graph(_ entities: [(String, EntityKind)],
                              _ relations: [(String, String, String)]) -> NoteGraph {
        NoteGraph(entities: entities.map { GraphEntity(name: $0.0, kind: $0.1) },
                  relations: relations.map { GraphRelation(from: $0.0, to: $0.1, type: $0.2) })
    }

    private static let sampleGraphs: [String: NoteGraph] = [
        "Apollo Kickoff": graph([("Sarah", .person), ("Marcus", .person), ("Apollo", .project)],
                                [("Sarah", "Apollo", "works on"), ("Marcus", "Apollo", "works on")]),
        "Website Redesign Sync": graph([("Priya", .person), ("Diego", .person), ("Website redesign", .project)],
                                       [("Priya", "Website redesign", "works on"), ("Diego", "Website redesign", "measures")]),
        "Acme Customer Call": graph([("Sarah", .person), ("Acme", .org), ("Apollo", .project)],
                                    [("Acme", "Apollo", "uses"), ("Sarah", "Acme", "supports")]),
        "Engineering Standup": graph([("Marcus", .person), ("Priya", .person), ("Apollo", .project), ("Deploy pipeline", .topic)],
                                     [("Marcus", "Deploy pipeline", "fixes"), ("Priya", "Apollo", "works on")]),
        "Q3 Pricing Review": graph([("Elena", .person), ("Diego", .person), ("Apollo", .project), ("Acme", .org), ("Pricing", .topic)],
                                   [("Elena", "Pricing", "owns"), ("Pricing", "Apollo", "part of"), ("Diego", "Acme", "briefs")]),
        "Hiring Sync": graph([("Elena", .person), ("Sarah", .person), ("Hiring", .topic)],
                             [("Elena", "Hiring", "leads"), ("Sarah", "Hiring", "interviews")]),
        "Northwind Partnership": graph([("Diego", .person), ("Elena", .person), ("Northwind", .org), ("Partnership", .topic)],
                                       [("Diego", "Partnership", "leads"), ("Partnership", "Northwind", "with")]),
        "Onboarding Revamp": graph([("Priya", .person), ("Sarah", .person), ("Onboarding", .project), ("Activation", .topic)],
                                   [("Priya", "Onboarding", "works on"), ("Sarah", "Activation", "defines")]),
        "Mobile App Planning": graph([("Marcus", .person), ("Priya", .person), ("Mobile app", .project), ("Apollo", .project)],
                                     [("Mobile app", "Apollo", "depends on"), ("Priya", "Mobile app", "works on"), ("Marcus", "Apollo", "works on")]),
        "Board Prep": graph([("Sarah", .person), ("Elena", .person), ("Churn", .topic), ("Fundraising", .topic)],
                            [("Sarah", "Churn", "tracks"), ("Elena", "Fundraising", "leads")]),
        "Acme Renewal": graph([("Sarah", .person), ("Diego", .person), ("Acme", .org), ("Apollo", .project)],
                              [("Acme", "Apollo", "renews"), ("Sarah", "Acme", "manages")]),
        "Team Retro": graph([("Elena", .person), ("Marcus", .person), ("Apollo", .project), ("Hiring", .topic)],
                            [("Elena", "Hiring", "closes"), ("Marcus", "Apollo", "works on")]),
    ]
}
