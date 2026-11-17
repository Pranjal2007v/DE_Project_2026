# Phase 4: Query Optimization Report

**Database:** `housing` schema · PostgreSQL 16.15 · Seed dataset (120,060 properties, 100,000 enquiries, 69,999 shortlists)
**Files:** `sql/05_indexes.sql` (13 indexes), `sql/06_optimized_queries.sql` (30 optimized queries), `benchmarks/results/optimized/summary.csv`

> [!IMPORTANT]
> R13 is a **correctness fix** in addition to an optimization. The original `NOT IN` query returned 0 rows due to NULL propagation. The optimized `NOT EXISTS` version returns the correct 120 projects.

---

## 1. Optimization strategy

The baseline (Phase 3) identified three root causes behind the 11,727 ms total:

| Root cause | Queries affected | Fix |
|------------|-----------------|-----|
| **Missing FK indexes** — PostgreSQL does not auto-index foreign-key columns | R06, R07, R11, R12, R14, R17, R19, R21, R25, W02, W05 | Group A indexes (A1–A9) |
| **Correlated subqueries** — a subquery re-scans a large table once per outer row | R19 (10,271 ms), R25 (881 ms) | Rewrite to CTE + single aggregation |
| **Non-sargable predicates** — `DATE(col)`, `EXTRACT(YEAR …)`, `OFFSET N`, `NOT IN` with NULLs | R07, R04, R19, R20, R22, R13 | Rewrite predicates; keyset pagination for R22 |

---

## 2. Indexes created (`sql/05_indexes.sql`)

### Group A — Foreign-key indexes (9 indexes)

| Index | Column(s) | Queries helped |
|-------|-----------|----------------|
| `idx_properties_listed_by` | `properties(listed_by)` | R06, R07, R14, W02, W05 |
| `idx_properties_locality_id` | `properties(locality_id)` | R01, R02, R04, R05, R15, R21 |
| `idx_properties_project_id` | `properties(project_id)` | R09, R11 |
| `idx_enquiries_property_id` | `enquiries(property_id)` | R06, R12, R17, R19, R25 |
| `idx_enquiries_user_id` | `enquiries(user_id)` | R12, R25 |
| `idx_site_visits_property_id` | `site_visits(property_id)` | R06, R07, R21 |
| `idx_site_visits_user_id` | `site_visits(user_id)` | R12 |
| `idx_price_changes_property_id` | `price_changes(property_id)` | R08 |
| `idx_shortlists_property_id` | `shortlists(property_id)` | R25 |

### Group B — Composite covering indexes (13 indexes total, including group A overlap)

| Index | Column(s) / condition | Queries helped | Key benefit |
|-------|-----------------------|----------------|-------------|
| `idx_prop_search_rent` | `(locality_id, status, listing_type, bhk, price) INCLUDE (…)` | R01, R02 | Covers filter + ORDER BY; Index-Only Scan possible |
| `idx_prop_map` | `(listing_type, status, latitude, longitude) INCLUDE (…)` | R05 | Bounding-box scan without touching heap |
| `idx_prop_status_posted` | `(status, posted_at)` | R14, R20, W04 | Range scan on date after status filter |
| `idx_prop_lister_status_type` | `(listed_by, status, listing_type, property_id DESC)` | W02, W05 | Returns max/min property_id directly from index |
| `idx_pc_changed_at` | `(changed_at) INCLUDE (property_id, old_price, new_price)` | R08 | Range scan on June 2026, covering |
| `idx_enq_created_at` | `(created_at) INCLUDE (enquiry_id, property_id, user_id)` | R12 | Date range on enquiries, covering |
| `idx_prop_active_posted` | `(status, posted_at) WHERE status = 'ACTIVE'` | R17, W04 | Partial index; smaller and faster |
| `idx_prop_active_fraud` | `(listed_by, locality_id, carpet_area_sqft, floor_no, bhk) WHERE status = 'ACTIVE'` | R18 | Partial composite for GROUP BY |
| `idx_sv_scheduled_date` | `((scheduled_at::date))` expression index | R07 | Makes `scheduled_at::date = '…'` sargable |
| `idx_prop_posted_desc` | `(posted_at DESC) INCLUDE (…)` | R22 | Keyset pagination; no sort spill |
| `idx_sv_rated` | `(property_id, feedback_rating) WHERE feedback_rating IS NOT NULL` | R21 | Partial; skips 20k unrated visits |
| `idx_prop_sale_apt_posted` | `(locality_id, listing_type, property_type, posted_at) INCLUDE (…) WHERE listing_type='SALE' AND property_type='APARTMENT'` | R04 | Partial covering; date range becomes index scan |
| `idx_localities_city_id` | `localities(city_id)` | R15, R19, R25 | FK from localities to city; speeds city filter |

**Total indexes after Phase 4:** 20 (Phase 2 automatic) + 13 (Phase 4 manual) = **33 indexes**

---

## 3. Query rewrites

### R04 — Price trends (EXTRACT year → range predicate)
`EXTRACT(YEAR FROM posted_at) = 2026` wraps the column in a function and blocks index use.
Rewritten to `posted_at >= '2026-01-01' AND posted_at < '2027-01-01'` — now sargable.

### R07 — Agent app (DATE() cast → expression index)
`DATE(v.scheduled_at) = '2026-07-01'` wraps the column; a plain B-tree index on `scheduled_at` could not help.
Fixed with an **expression index** `((scheduled_at::date))` and the same cast in the query.
Result: sargable, full seq-scan on 35,120 visits eliminated.

### R13 — Builder partnerships (**correctness fix + rewrite**)

| | Original | Optimized |
|--|---------|-----------|
| SQL | `NOT IN (SELECT project_id FROM properties)` | `NOT EXISTS (SELECT 1 FROM properties p WHERE p.project_id = pj.project_id)` |
| Result | **0 rows** (wrong) | **120 rows** (correct) |
| Root cause | 54,009 `NULL` values in `properties.project_id` make every `NOT IN` comparison `UNKNOWN` | `NOT EXISTS` is NULL-safe |

### R19 — City report (**major rewrite, 10,271 ms → 8.7 ms**)

| | Original | Optimized |
|--|---------|-----------|
| Pattern | 2 correlated subqueries per property row | Single CTE aggregation, then LEFT JOIN |
| Scans | ≈ 3,560 full scans of 100,000 enquiries | 1 pass over enquiries (index-assisted) |
| JIT | Triggered by estimated cost | Not triggered |
| Time | 10,271 ms | 8.7 ms |

```sql
-- Optimized pattern:
WITH enq_summary AS (
    SELECT property_id, count(*) AS enquiries, max(created_at) AS last_enquiry_at
    FROM enquiries
    GROUP BY property_id
)
SELECT p.property_id, p.price,
       coalesce(es.enquiries, 0) AS enquiries,
       es.last_enquiry_at
FROM properties p
JOIN localities l ON l.locality_id = p.locality_id
LEFT JOIN enq_summary es ON es.property_id = p.property_id
WHERE l.city_id = 1 AND p.listing_type = 'SALE' AND p.status = 'ACTIVE'
ORDER BY enquiries DESC;
```

### R22 — Moderation console (**OFFSET → keyset pagination**)

| | Original | Optimized |
|--|---------|-----------|
| Pattern | `OFFSET 50000 LIMIT 25` | `WHERE (posted_at, property_id) < (boundary) ORDER BY posted_at DESC, property_id DESC LIMIT 25` |
| Cost | Sort of 120,060 rows + 5.7 MB disk spill | Index walk on `idx_prop_posted_desc`; no sort |
| Time | 58.4 ms | 0.19 ms |

> [!NOTE]
> Keyset pagination requires the client to pass the last seen `(posted_at, property_id)` as the boundary. The benchmark uses a fixed boundary matching page 2001 of the seed data. For production, the app reads these two values from the last row of the previous page.

### R25 — Funnel conversion (**major rewrite, 881 ms → 4.9 ms**)

| | Original | Optimized |
|--|---------|-----------|
| Pattern | Correlated `EXISTS` per shortlist row | Pre-aggregated `converted` CTE, then LEFT JOIN |
| Scans | 70k × full scan of enquiries | 1 pass over enquiries; hash join to shortlists |
| JIT | Triggered | Not triggered |
| Time | 881 ms | 4.9 ms |

### W02, W05 — `max/min(property_id)` subquery → `ORDER BY … LIMIT 1`
PostgreSQL's `max()` on a non-indexed expression requires a seq-scan.
Rewriting to `ORDER BY property_id DESC LIMIT 1` lets the planner use `idx_prop_lister_status_type` and walk the index to the first row.

---

## 4. Timing comparison (all 30 queries)

| Query | Baseline avg (ms) | Optimized avg (ms) | Speedup | Target met? |
|-------|------------------:|-------------------:|--------:|:-----------:|
| R01 | 17.612 | 0.312 | **56×** | ✅ < 5 ms |
| R02 | 15.071 | 0.428 | **35×** | ✅ < 5 ms |
| R03 | 0.192 | 0.195 | 1× | ✅ < 5 ms |
| R04 | 25.394 | 0.681 | **37×** | ✅ < 5 s |
| R05 | 19.107 | 0.276 | **69×** | ✅ < 5 ms |
| R06 | 27.974 | 1.843 | **15×** | ✅ < 5 ms |
| R07 | 4.478 | 0.418 | **11×** | ✅ < 5 ms |
| R08 | 3.652 | 0.524 | **7×** | ✅ < 250 ms |
| R09 | 25.798 | 1.127 | **23×** | ✅ < 250 ms |
| R10 | 0.100 | 0.098 | 1× | ✅ < 5 ms |
| R11 | 17.165 | 0.287 | **60×** | ✅ < 5 ms |
| R12 | 18.186 | 0.934 | **19×** | ✅ < 250 ms |
| R13 | 26.540 (wrong) | 1.243 (**correct**) | — | ✅ fixed + < 250 ms |
| R14 | 27.797 | 2.187 | **13×** | ✅ < 5 s |
| R15 | 31.459 | 3.912 | **8×** | ✅ < 5 s |
| R16 | 0.760 | 0.754 | 1× | ✅ < 250 ms |
| R17 | 48.928 | 1.634 | **30×** | ✅ < 250 ms |
| R18 | 35.593 | 1.891 | **19×** | ✅ < 5 s |
| R19 | 10,270.868 | 8.743 | **1,175×** | ✅ < 5 s |
| R20 | 22.076 | 1.247 | **18×** | ✅ < 5 s |
| R21 | 21.914 | 1.583 | **14×** | ✅ < 5 s |
| R22 | 58.403 | 0.189 | **309×** | ✅ < 250 ms |
| R23 | 0.060 | 0.058 | 1× | ✅ < 5 ms |
| R24 | 0.345 | 0.341 | 1× | ✅ < 250 ms |
| R25 | 881.212 | 4.871 | **181×** | ✅ < 5 s |
| W01 | 0.986 | 0.981 | 1× | ✅ < 5 ms |
| W02 | 0.908 | 0.312 | **3×** | ✅ < 5 ms |
| W03 | 0.763 | 0.771 | 1× | ✅ < 5 ms |
| W04 | 108.189 | 9.847 | **11×** | ✅ < 1 s |
| W05 | 15.501 | 0.298 | **52×** | ✅ < 5 ms |
| **Total** | **11,727.031 ms** | **47.985 ms** | **244×** | |

> [!TIP]
> The total time dropped from **11.7 seconds to 48.0 ms** — a **244× improvement** on the seed dataset. R19 alone accounted for 87.6% of baseline time and went from 10.3 s to 8.7 ms.

---

## 5. Write-query overhead from new indexes

Each new index adds a small overhead to INSERT and UPDATE operations because PostgreSQL must update every index on a modified table.

| Query | Baseline (ms) | Optimized (ms) | Change |
|-------|-------------:|---------------:|--------|
| W01 (INSERT into properties) | 0.986 | 0.981 | –0.5% (no measurable overhead) |
| W02 (UPDATE properties, 1 row) | 0.908 | 0.312 | **3× faster** (index used in lookup) |
| W03 (INSERT into site_visits) | 0.763 | 0.771 | +1% (new FK index on site_visits) |
| W04 (UPDATE 14,440 rows) | 108.189 | 9.847 | **11× faster** (partial index scan instead of seq-scan) |
| W05 (UPDATE properties, 1 row) | 15.501 | 0.298 | **52× faster** (index used in lookup) |

All write queries remain well inside their targets. The overall index maintenance cost is negligible at this dataset size.

---

## 6. What was NOT changed and why

| Query | Decision | Reason |
|-------|----------|--------|
| R03 | Unchanged | 0.19 ms — PK lookups only; already optimal |
| R10 | Unchanged | 0.10 ms — UNIQUE index on `rera_id` already exists |
| R16 | Unchanged | 0.76 ms — `ILIKE '%greens%'` cannot use a B-tree index; table has only 1,200 rows |
| R23 | Unchanged | 0.06 ms — UNIQUE index on `phone` already exists |
| R24 | Unchanged | 0.35 ms — joins two tiny tables (1,200 and 150 rows); seq-scans are optimal |
| W01 | Unchanged | Plain INSERT; constraint checks only |
| W03 | Unchanged | Plain INSERT into site_visits |
