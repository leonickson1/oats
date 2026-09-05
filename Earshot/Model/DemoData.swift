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
}
