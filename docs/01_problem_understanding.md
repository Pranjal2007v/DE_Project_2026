# Phase 1: Problem Understanding

**Project:** Housing.com Property Search Database · **Data:** 120,060 listings, 40,000 users, 10 cities · **Expected growth:** 20×

RT = customer-facing / real-time (a person is waiting). RA = reporting / analytics (internal or scheduled work).
Targets come from the large-dataset round (Phase 5): real-time < 5 ms, interactive tools < 250 ms, reports < 5 s, batch < 1 s.

| # | What the business needs (in our words) | Stakeholder | Type | Queries and target |
|---|----------------------------------------|-------------|------|--------------------|
| P1 | Searching homes to rent or buy must feel instant: filters (BHK, budget, furnishing, locality), best price per sq ft first, listings inside the visible map area, and amenity filters. | Home seeker (tenant / buyer) | **RT** | R01, R02, R05 < 5 ms; R09, R16 < 250 ms |
| P2 | A property page, a project page and a RERA lookup must open without lag. A buyer checks the project, builder, amenities, RERA registration and whether possession is delayed. | Home seeker (buyer), builder | **RT** | R03, R10, R11 < 5 ms; R24 < 250 ms |
| P3 | Owners and agents must manage listings quickly: dashboard with enquiry and visit counts, the day's site-visit schedule, posting a listing, cutting the price, changing the status, and a seeker booking a visit. | Owner, agent (seeker for W03) | **RT** | R06, R07, W01, W02, W03, W05 < 5 ms |
| P4 | An hourly job must tell seekers about price drops, give agents the enquiries that never became a visit, and nudge owners whose listings get no enquiries. It must finish well inside the hour. | Growth / engagement team (end users: seeker, owner, agent) | **RA** (scheduled job) | R08, R12, R17 < 250 ms |
| P5 | The partnerships team needs the list of projects with no listing on the platform. It is always empty, so this is a **wrong result**, not a speed problem. | Builder (partnerships team) | **RA** | R13 < 250 ms |
| P6 | Business insights (monthly price trend, rental yield by locality, agent leaderboard, visit ratings per locality, shortlist-to-enquiry funnel) must finish instead of timing out. | Investor, agent, growth team, seeker (ratings) | **RA** | R04, R14, R15, R21, R25 < 5 s |
| P7 | Trust & safety and platform reports (duplicate-listing fraud, city report, growth per day, moderation console, nightly clean-up) must stay fast as listings grow 20×. Sign-in by mobile number is the one customer-facing query in this group. | Trust & safety, platform / ops, growth; every user for sign-in | **RA** (R23 is **RT**, W04 is batch) | R18, R19, R20 < 5 s; R22 < 250 ms; R23 < 5 ms; W04 < 1 s |

**Summary:** 13 of the 30 queries are real-time (P1–P3 and R23). Their cost is dominated by lookups, so indexes matter most. The rest are interactive tools, reports and one batch job, where scans and aggregations dominate.

**Early finding on P5 (checked on the seed data):** 54,009 of 120,060 properties have `project_id = NULL`. R13 uses `NOT IN (SELECT project_id ...)`, and a single NULL in that list makes the whole predicate UNKNOWN. R13 returns **0 rows**, but **120 projects** really have no listing (checked with `NOT EXISTS`). This is a correctness bug, to be fixed and explained in Phase 4.

## Assumptions
1. The 12 CSV files are a faithful export of production and there are no other tables.
2. Constraints must accept every seed row. Data problems are documented, not silently cleaned.
3. `price` is the **current** price: monthly rent for RENT, total price for SALE. `price_changes` is the history log.
4. `ACTIVE` means currently visible to seekers. `RENTED` applies only to rentals and `SOLD` only to sales.
5. All times are IST (+05:30). Benchmarks run with session time zone `Asia/Kolkata`, because the queries compare timestamps with date literals.
6. The queries treat 1 July 2026 as "today", so the data is a snapshot as of 30 June 2026.
7. Each user has exactly one role (`SEEKER`, `OWNER` or `AGENT`).
8. The workload is read-heavy (25 reads, 5 writes) and all tables grow about 20× together.
9. Optimized queries must return the same rows as the originals, except where the original is wrong (R13), where we fix the answer and explain it.
