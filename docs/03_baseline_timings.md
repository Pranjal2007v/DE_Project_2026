# Phase 3: Baseline timings (before any optimization)

Measured on **17 November 2026** on the Phase 2 database: only the constraints from `sql/01_schema.sql`, with **20 indexes, all created automatically by PRIMARY KEY / UNIQUE constraints** and nothing added by hand. Tables were loaded with `sql/02_load_data.sql` and `ANALYZE` was run.

## How it was measured

| Item | Value |
|------|-------|
| Command | `./benchmarks/run_benchmark.sh housing_cp2 baseline` |
| Method | Every query runs 3 times with `EXPLAIN (ANALYZE, BUFFERS)`. The `Execution Time` line is recorded and the three values are averaged |
| Write queries | W01–W05 run inside `BEGIN; … ROLLBACK;`, so the data does not change |
| Server | PostgreSQL 16.15 on Linux, 2 vCPU (Intel Xeon 2.1 GHz), 8 GB RAM |
| Settings | PostgreSQL defaults, nothing tuned: `shared_buffers` 128 MB, `work_mem` 4 MB, `jit` on, 2 parallel workers per gather |
| Time zone | The database time zone is `Asia/Kolkata`, because the queries compare timestamps with date literals |
| Data | Seed data: 120,060 properties, 100,000 enquiries, 69,999 shortlists, 40,000 users, 35,120 site visits (database size 64 MB) |
| Cache | The three runs of a query run one after another, so the first run can be a little slower than the other two |

Raw plans of all three runs are saved in `benchmarks/results/baseline/R01.txt … W05.txt`, and the summary is in `benchmarks/results/baseline/summary.csv` (average, median, min, max and scan types).

## Timing table (all 30 queries)

| SQL Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---:|---:|---:|---:|
| R01: Rent search: active 2 BHK homes in Koramangala up to ₹40,000/month, furnished or semi-furnished | READ | 19.535 | 15.333 | 17.968 | 17.612 |
| R02: Buy search: 3 BHK apartments for sale in Pune under ₹1.2 crore, best price per sq ft first | READ | 14.019 | 15.353 | 15.840 | 15.071 |
| R03: Property page: property 6897 with its project, builder and project amenities | READ | 0.187 | 0.200 | 0.189 | 0.192 |
| R04: Price trends: average sale price per sq ft of apartments in Whitefield, per month in 2026 | READ | 28.847 | 23.607 | 23.727 | 25.394 |
| R05: Map view: active rentals inside the visible map area of central Bengaluru | READ | 17.437 | 19.441 | 20.442 | 19.107 |
| R06: Owner dashboard: owner 1033's listings with enquiry and site-visit counts | READ | 32.958 | 28.446 | 22.519 | 27.974 |
| R07: Agent app: site visits scheduled on 1 July 2026 for properties listed by user 4723 | READ | 4.605 | 4.396 | 4.432 | 4.478 |
| R08: Price-drop alerts: active properties whose price fell by 10% or more in June 2026 | READ | 3.173 | 3.224 | 4.558 | 3.652 |
| R09: Amenity filter: active properties in projects that have a gym AND a swimming pool AND power backup | READ | 22.076 | 33.066 | 22.252 | 25.798 |
| R10: Buyer due diligence: look up a project by its RERA registration id | READ | 0.124 | 0.091 | 0.085 | 0.100 |
| R11: Project page: available listings in project 217 by BHK with the price range | READ | 18.927 | 16.915 | 15.654 | 17.165 |
| R12: Lead follow-up: June 2026 enquiries with no site visit booked for that property by that user | READ | 18.891 | 17.657 | 18.009 | 18.186 |
| R13: Builder partnerships: projects with no property listed on Housing.com | READ | 22.925 | 28.625 | 28.070 | 26.540 |
| R14: Agent leaderboard: agents with the most properties sold or rented in 2026 | READ | 29.823 | 26.983 | 26.586 | 27.797 |
| R15: Investor insights: rental yield by Bengaluru locality (yearly rent per sq ft ÷ sale price per sq ft) | READ | 25.380 | 40.342 | 28.656 | 31.459 |
| R16: Search box: projects with "greens" in the name | READ | 1.246 | 0.516 | 0.519 | 0.760 |
| R17: Owner nudges: active listings older than 90 days that have never received an enquiry | READ | 47.861 | 50.627 | 48.295 | 48.928 |
| R18: Fraud checks: the same flat (locality, area, floor, BHK) listed more than once by the same lister | READ | 36.530 | 33.827 | 36.421 | 35.593 |
| R19: City report: enquiries and latest enquiry for every active sale property in Bengaluru | READ | 12126.687 | 9296.325 | 9389.592 | 10270.868 |
| R20: Growth: new listings per day and running total, June 2026 | READ | 18.681 | 29.110 | 18.436 | 22.076 |
| R21: Experience: average site-visit rating per locality (at least 10 rated visits) | READ | 22.227 | 21.790 | 21.725 | 21.914 |
| R22: Listing moderation console: all listings, newest first, page 2,001 (25 per page) | READ | 49.235 | 48.532 | 77.441 | 58.403 |
| R23: Sign-in with mobile number | READ | 0.069 | 0.057 | 0.054 | 0.060 |
| R24: Buyer protection: under-construction projects whose promised possession date has already passed | READ | 0.359 | 0.338 | 0.339 | 0.345 |
| R25: Funnel: shortlists that turned into an enquiry, per city | READ | 771.192 | 917.720 | 954.723 | 881.212 |
| W01: Post property: owner 1033 lists a 2 BHK for rent in Koramangala | WRITE | 1.001 | 1.007 | 0.951 | 0.986 |
| W02: Price cut: owner 1033 reduces the rent of their most recent active rental by 5% | WRITE | 0.952 | 0.889 | 0.883 | 0.908 |
| W03: Book a site visit: seeker 1042 visits property 6897 on 4 July 2026 at 11:00 | WRITE | 0.842 | 0.773 | 0.673 | 0.763 |
| W04: Nightly job: deactivate active listings older than 120 days | WRITE | 112.724 | 108.991 | 102.853 | 108.189 |
| W05: Owner 1033 marks their oldest active rental as rented | WRITE | 23.169 | 11.753 | 11.581 | 15.501 |
| **Total (sum of all 30)** | | | | | **11727.031** |

## Scan type and why each query is slow or fast

| Query | Scan type (from the plan) | Why |
|-------|---------------------------|-----|
| R01 | Seq Scan on properties, localities | Reads the whole properties table to return 25 rows; there is no index on locality, status, BHK or price |
| R02 | Seq Scan on properties, localities | Same: full scan of properties, then a sort by price per sq ft on the matching rows |
| R03 | Index Scan (PK) on properties, projects, builders, amenities; Index Only Scan on project_amenities | One property found by primary key, and every join follows a primary key, so only a few rows are touched (0.19 ms) |
| R04 | Seq Scan on properties, localities | Filters 120k rows by locality, type and date range, then groups by month; no index on `posted_at` |
| R05 | Seq Scan on properties | Tests status, type and a latitude/longitude box row by row until 200 matches are found; no index on the coordinates |
| R06 | Seq Scan on properties, enquiries, site_visits | `listed_by` and the `property_id` foreign keys have no index, so enquiries (100k) and site visits (35k) are read in full and hash-joined |
| R07 | Seq Scan on site_visits; Index Scan (PK) on properties, users | `date(scheduled_at) = '2026-07-01'` wraps the column in a function, so an index on `scheduled_at` could not help; all 35,120 visits are read |
| R08 | Seq Scan on price_changes; Index Scan (PK) on properties | Reads all 23,425 price changes to find the June ones (no index on `changed_at`), then looks up each property by primary key |
| R09 | Seq Scan on properties, project_amenities, amenities | Reads active properties and the amenity links in full, then groups by project to keep those with all 3 amenities |
| R10 | Index Scan on projects (`uq_projects_rera`); Seq Scan on builders | The UNIQUE constraint on `rera_id` already gives an index; the Seq Scan on builders reads only 150 rows |
| R11 | Seq Scan on properties | `project_id = 217` has no index (foreign keys are not indexed), so 120,041 rows are read and thrown away |
| R12 | Seq Scan on enquiries, site_visits | A hash anti-join that reads both tables in full; the June filter on enquiries has no index |
| R13 | Seq Scan on projects, properties | Fast (26 ms) but **wrong**: it returns 0 rows, see the finding below |
| R14 | Seq Scan on properties, users | Reads all properties for the SOLD/RENTED and date filters, joins to agents, then aggregates and sorts |
| R15 | Seq Scan on properties, localities | Computes rent and sale price per sq ft for Bengaluru localities from a full scan of properties |
| R16 | Seq Scan on projects | `ILIKE '%greens%'` cannot use a normal B-tree index, but the table has only 1,200 rows and `LIMIT 30` stops early (0.76 ms) |
| R17 | Seq Scan on enquiries, properties | An anti-join (no enquiry for the property) that reads both tables in full |
| R18 | Seq Scan on properties | `GROUP BY ... HAVING count(*) > 1` has to see every active listing, then sort the groups |
| R19 | Seq Scan on properties, localities, enquiries | **Slowest query.** Two correlated subqueries run once per property (1,780 properties × 2), and each one scans all 100,000 enquiries. That is about 3,560 full scans of enquiries (3.2 million buffer hits). JIT compilation adds about 240 ms |
| R20 | Seq Scan on properties | Full scan for the June date range, then a window function for the running total |
| R21 | Seq Scan on properties, site_visits, localities | Joins three tables with full scans, then groups by locality with `HAVING count(*) >= 10` |
| R22 | Seq Scan on properties | `OFFSET 50000` sorts all 120,060 rows by `posted_at` (the sort spills 5.7 MB to disk because `work_mem` is 4 MB) and throws away 50,000 of them to return 25 |
| R23 | Index Scan on users (`uq_users_phone`) | The UNIQUE constraint on `phone` gives an index; one row is read (0.06 ms, the fastest query) |
| R24 | Seq Scan on projects, builders | Tiny tables (1,200 and 150 rows), so a full scan is cheap |
| R25 | Index Scan on localities (`uq_localities_city_name`); Seq Scan on shortlists, properties, enquiries | The join to localities is a nested loop that re-reads 69,999 rows 100 times (6.9 million rows discarded); the `EXISTS` check scans all enquiries. JIT adds about 210 ms |
| W01 | (no scan) | Plain INSERT: only the primary key, unique and foreign-key checks (about 1 ms) |
| W02 | Index Scan (PK) on properties | Walks the primary key index backwards to find owner 1033's latest active rental and discards 3,150 rows on the way (no index on `listed_by`); then updates one row |
| W03 | (no scan) | Plain INSERT into site_visits (about 0.8 ms) |
| W04 | Seq Scan on properties | Scans all properties and updates 14,440 rows; the cost is mostly the update itself (108 ms) |
| W05 | Index Scan (PK) on properties | Same idea as W02, but the first match is far into the index, so 53,025 rows are discarded first (15.5 ms against 0.9 ms for W02) |

## What the baseline shows

1. **Total time is 11,727 ms, and two queries make up 95% of it.** R19 (10,271 ms, 87.6%) and R25 (881 ms, 7.5%) are the only reads above 100 ms. The other 28 queries together take 575 ms.
2. **26 of the 30 queries finish under 50 ms.** Only R19, R22, R25 and W04 are at or above 50 ms. Eight queries finish under 1 ms: R03, R10, R16, R23, R24, W01, W02 and W03.
3. **24 of the 30 queries contain a Seq Scan.** The six without one are R03, R23, W01, W02, W03 and W05. The fast ones are fast because they use a primary key or UNIQUE index (R03, R10, R23) or touch tiny tables (R16, R24).
4. **Foreign-key columns have no indexes.** PostgreSQL does not create them, so `properties.listed_by`, `properties.project_id`, `properties.locality_id` and `enquiries.property_id` are read by full scans in R06, R11, R17, R19 and R25.
5. **Patterns that block an index**, to fix in Phase 4: a function on the column (R07), correlated subqueries (R19, R25), `OFFSET` pagination (R22) and `ILIKE '%text%'` (R16).
6. **R13 gives a wrong answer, not just a slow one.** 54,009 properties have `project_id = NULL`. In `NOT IN (SELECT project_id ...)` a single NULL makes the condition UNKNOWN for every project, so R13 returns **0 rows**. The same question with `NOT EXISTS` returns **120 projects** that really have no listing. This is fixed in Phase 4.
7. **Write queries are cheap except W04.** W01–W03 take about 1 ms each; W05 takes 15.5 ms because it walks the primary key index; W04 takes 108 ms because it updates 14,440 rows. Every index added in Phase 4 will make these writes a little slower, so they are measured again.
8. **Two plans used JIT** (R19 and R25, about 210–240 ms each). That is the planner's reaction to their very high estimated cost, and it disappears once the queries are rewritten.

## Notes
- Timings vary by a few milliseconds between runs (R15 ranges from 25 to 40 ms), so the average of 3 is used. Differences smaller than that are not meaningful.
- Phase 4 and Phase 5 must be measured on the **same machine and with the same method** as this baseline, otherwise the before/after comparison is not fair.
