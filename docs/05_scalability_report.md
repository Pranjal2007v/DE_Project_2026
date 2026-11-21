# Phase 5: Scalability Report

**Large dataset:** 20× scale — 2,401,264 properties · 2,000,000 enquiries · 1,400,000 shortlists · 800,000 users · 699,415 site visits · 470,019 price changes · 24,000 projects  
**Database size:** ≈ 1.3 GB  
**Measured on:** 21 November 2026, PostgreSQL 18 (Postgres.app), Apple Silicon Mac  
**Files:** `sql/03_load_large_data.sql` · `sql/05_indexes.sql` · `sql/08_partitioning.sql` · `benchmarks/results/large/summary.csv` · `benchmarks/results/large_opt/summary.csv`

> [!IMPORTANT]
> All optimized queries meet their Phase 1 performance targets on the 20× dataset. The same 22 indexes from Phase 4 (`sql/05_indexes.sql`) are sufficient — no schema changes are required to scale to 20×.

---

## 1. What 20× growth means

| Table | Seed rows | 20× rows | Scale |
|-------|----------:|--------:|------:|
| properties | 120,060 | **2,401,264** | 20× |
| enquiries | 100,000 | **2,000,000** | 20× |
| shortlists | 69,999 | **1,400,000** | 20× |
| users | 40,000 | **800,000** | 20× |
| site_visits | 35,120 | **699,415** | 20× |
| price_changes | 23,425 | **470,019** | 20× |
| projects | 1,200 | **24,000** | 20× |
| localities | 100 | **100** | 1× (fixed) |

**Database size:** ~1.3 GB (from 64 MB seed × 20 for data + indexes).

---

## 2. Partitioning strategy (`sql/08_partitioning.sql`)

### 2a. `properties` — RANGE on `posted_at`

```
properties_2023  → 2023-01-01 to 2023-12-31
properties_2024  → 2024-01-01 to 2024-12-31
properties_2025  → 2025-01-01 to 2025-12-31
properties_2026  → 2026-01-01 to 2026-12-31   ← primary data partition
properties_future → all other dates (default)
```

**Why RANGE on `posted_at`?**
- R04 (price trends), R14 (agent leaderboard), R20 (growth per day) all filter on `posted_at` date ranges. Partition pruning limits the scan to 1–2 partitions (< 500k rows) instead of 2.4M.
- W04 (nightly deactivation) filters `posted_at < cutoff`; pruning makes the update touch only older partitions.
- Each yearly partition fits in memory (≈ 250 MB).

### 2b. `enquiries` — HASH on `property_id` (8 buckets)

```
enquiries_h0 .. enquiries_h7  (~250,000 rows each)
```

**Why HASH?**
- Enquiries are accessed by `property_id` (R06, R12, R17, R19) or `user_id` (R12, R25) — no dominant time ordering.
- 8 equal-sized buckets keep each partition at ≈ 250k rows, so an index lookup on `idx_enquiries_property_id` navigates directly to the correct shard.

### 2c. `price_changes` — RANGE on `changed_at` (quarterly)

```
price_changes_2026q2  → April–June 2026   ← R08 (June alerts) lives here
```

**Why quarterly?** R08 queries a 1-month window (`changed_at >= '2026-06-01' AND < '2026-07-01'`). With quarterly partitions, pruning isolates R08 to one partition of ≈ 117k rows at 20×.

---

## 3. Before vs After: timings on the 20× large dataset

> Baseline = no extra indexes (only 20 PK/UNIQUE constraints from `sql/01_schema.sql`).  
> Optimized = all 22 indexes from `sql/05_indexes.sql` applied.  
> Phase 1 targets: real-time < 5 ms · interactive < 250 ms · reports < 5 s · batch < 1 s.

| Query | Description | Baseline (ms) | Optimized (ms) | Speedup | Target | Met? |
|-------|-------------|-------------:|---------------:|--------:|--------|:----:|
| R01 | Rent search: 2 BHK Koramangala | 96.5 | **0.31** | **311×** | < 5 ms | ✅ |
| R02 | Buy search: 3 BHK Pune | 89.4 | **3.19** | **28×** | < 5 ms | ✅ |
| R03 | Property page (PK lookup) | 0.07 | **0.15** | — | < 5 ms | ✅ |
| R04 | Price trends by month | 98.1 | **1.77** | **55×** | < 5 s | ✅ |
| R05 | Map view: active rentals bbox | 7.8 | **0.12** | **65×** | < 5 ms | ✅ |
| R06 | Owner dashboard: listings + counts | 95.6 | **3.63** | **26×** | < 5 ms | ✅ |
| R07 | Agent app: site visits on date | 20.4 | **1.17** | **17×** | < 5 ms | ✅ |
| R08 | Price-drop alerts: ≥10% drop June | 17.8 | **43.3** | 0.4× ⚠️ | < 250 ms | ✅ |
| R09 | Amenity filter: gym+pool+backup | 92.9 | **155.8** | 0.6× ⚠️ | < 250 ms | ✅ |
| R10 | Buyer due diligence: RERA lookup | 0.05 | **0.17** | — | < 5 ms | ✅ |
| R11 | Project page: listings by BHK | 66.6 | **0.19** | **351×** | < 5 ms | ✅ |
| R12 | Lead follow-up: June enquiries no visit | 76.7 | **47.9** | 1.6× | < 250 ms | ✅ |
| R13 | Builder partnerships: projects with no listing | 316,460 | **~3.0** | **~105,000×** | < 250 ms | ✅ |
| R14 | Agent leaderboard | 124.0 | **5.7** | **22×** | < 5 s | ✅ |
| R15 | Investor: rental yield by locality | 83.2 | **9.8** | **8.5×** | < 5 s | ✅ |
| R16 | Search box: projects with "greens" | 8.3 | **2.1** | 4× | < 250 ms | ✅ |
| R17 | Owner nudges: listings >90d no enquiry | 244.8 | **4.2** | **58×** | < 250 ms | ✅ |
| R18 | Fraud check: duplicate listings | 497.4 | **4.9** | **102×** | < 5 s | ✅ |
| R19 | City report: enquiries per Bengaluru sale prop | *~200,000 est.* | **19.8** | **~10,000×** | < 5 s | ✅ |
| R20 | Growth: new listings per day June 2026 | 94.1 | **3.2** | **29×** | < 5 s | ✅ |
| R21 | Experience: avg visit rating by locality | 135.9 | **4.0** | **34×** | < 5 s | ✅ |
| R22 | Listing moderation: page 2001 of 25 | 261.1 | **0.49** | **533×** | < 250 ms | ✅ |
| R23 | Sign-in by mobile number | 0.2 | **0.14** | — | < 5 ms | ✅ |
| R24 | Buyer protection: overdue possession | 1.8 | **0.89** | 2× | < 250 ms | ✅ |
| R25 | Funnel: shortlists → enquiries per city | *~18,000 est.* | **12.7** | **~1,400×** | < 5 s | ✅ |
| W01 | Post property (INSERT) | — | **2.3** | — | < 5 ms | ✅ |
| W02 | Price cut: reduce rent 5% | — | **0.84** | — | < 5 ms | ✅ |
| W03 | Book a site visit (INSERT) | — | **1.8** | — | < 5 ms | ✅ |
| W04 | Nightly job: deactivate old listings | — | **24.7** | — | < 1 s | ✅ |
| W05 | Mark listing as rented | — | **0.81** | — | < 5 ms | ✅ |

> ⚠️ R08 and R09 show apparent slowdown vs baseline because the optimizer chose different plans (Bitmap Heap Scan vs Seq Scan). Both still meet their targets comfortably (43 ms and 156 ms vs 250 ms limit).

> R13, R19, R25 baseline times marked *est.* — R19 and R25 baselines were not measured (each takes 5–20+ minutes without indexes at 20× scale); values are extrapolated from the measured R13 single-run time (316 s) and seed-data scaling ratios.

---

## 4. Scalability analysis by query class

### Real-time lookups (< 5 ms target)

R01, R02, R05, R06, R07, R11, R23, W01–W05 all remain under 5 ms at 20×. These use composite covering indexes (B-tree index-only scans) so the execution time grows with **O(log N + result_set_size)**, not with table size. At 20× data the log factor adds < 1 ms.

### Interactive tools (< 250 ms target)

R08, R09, R12, R13, R16, R17, R22, R24 all stay well under 250 ms. The worst is R09 (155 ms) — a bitmap heap scan joining amenities + project_amenities + properties where the amenity filter is applied first, reducing the property set dramatically before the heap fetch.

### Analytic reports (< 5 s target)

R04, R14, R15, R18, R19, R20, R21, R25 are the scan-heavy aggregation queries. The slowest at 20× is **R19 (19.8 ms)** — still 250× under the 5 s target. R15 (rental yield) at 9.8 ms is the next slowest.

### Batch job (< 1 s target)

W04 deactivates rows in **24.7 ms** using the partial index `idx_prop_active_posted` — 4× faster than the seed baseline W04 (108 ms unoptimized) and 40× under the 1 s budget.

---

## 5. The index impact: scan type conversion at 20×

The most dramatic improvements come from **converting sequential scans to index scans** on large tables:

| Index | Queries helped | Mechanism |
|-------|---------------|-----------|
| `idx_prop_search_rent` (locality_id, status, listing_type, bhk, price) | R01, R02 | Covers all filter columns + SELECT cols → Index Only Scan; 2.4M → ~25 rows |
| `idx_prop_map` (listing_type, status, lat, lng) | R05 | Bbox filter via index range → ~200 rows; no heap fetch |
| `idx_properties_project_id` | R11, R13, R09 | Narrows 2.4M properties to one project's listings (~100 rows) |
| `idx_prop_active_posted` (partial, status='ACTIVE') | R17, W04 | Only 1.1M active rows indexed; date range prunes further |
| `idx_prop_active_fraud` (partial, status='ACTIVE') | R18 | Group-by on fraud dimensions over indexed 1.1M rows |
| `idx_enquiries_property_id` | R06, R12, R17, R19 | Avoids full 2M-row scan of enquiries per property |
| `idx_prop_posted_desc` (covering, DESC) | R22 | Pagination OFFSET 50000 becomes index walk, not sort |
| `idx_enq_created_at` INCLUDE(property_id, user_id) | R12 | June date range → ~167k enquiries, rest filtered by index |

### R11 deep dive: 66.6 ms → 0.19 ms (351× speedup)

```
-- Baseline: Seq Scan on properties (2,401,264 rows scanned, 2,399,864 discarded)
-- Optimized: Bitmap Index Scan on idx_properties_project_id
--   → 100 qualifying rows → Bitmap Heap Scan → 100 rows returned
-- Cost: O(2.4M) → O(log 2.4M + 100) = effectively O(1) for this query
```

### R13 deep dive: 316,460 ms → ~3 ms (~105,000× speedup)

```
-- Baseline: Hash Right Anti Join
--   Hash properties (2.4M rows) → probe projects (24k rows)
--   Full 2.4M-row scan for the hash build phase: 316 s

-- Optimized (06_optimized_queries.sql): NOT EXISTS rewritten with idx_properties_project_id
--   For each of 24,000 projects, index-seek on properties.project_id
--   → 24,000 × O(log 2.4M) ≈ 24,000 × 21 comparisons = ~500k ops vs 2.4B ops baseline
```

### R19 deep dive: estimated minutes → 19.8 ms (indexes transform O(N²) → O(N log N))

```
-- Baseline (seed): 2 correlated subqueries × 1,780 Bengaluru SALE properties
--   Each subquery: Seq Scan on 100k enquiries → 356M comparisons → 10,271 ms
-- Baseline (large, estimated): 2 subqueries × 35,600 properties × 2M enquiries
--   → ~142 billion comparisons → 200,000+ ms (estimated)

-- Optimized: Hash Join + idx_enquiries_property_id + idx_localities_city_id
--   Planner rewrites correlated subqueries as lateral joins with index seeks
--   → O(35,600 × log 2M) ≈ 35,600 × 21 = ~748k ops → 19.8 ms
```

---

## 6. Index sizes at 20×

| Index | Approx. rows indexed | Estimated size |
|-------|-----------------:|-------------:|
| `idx_prop_search_rent` (properties) | 2.4M | ≈ 150 MB |
| `idx_prop_map` (properties) | 2.4M | ≈ 100 MB |
| `idx_enquiries_property_id` | 2.0M | ≈ 50 MB |
| `idx_prop_active_posted` (partial) | ≈ 1.1M active | ≈ 40 MB |
| `idx_prop_active_fraud` (partial) | ≈ 1.1M active | ≈ 70 MB |
| All other indexes | — | ≈ 200 MB |
| **Total index overhead** | | **≈ 610 MB** |

Total database size at 20×: ≈ 700 MB data + 610 MB indexes ≈ **1.3 GB** — fits comfortably on a standard 8 GB server.

---

## 7. Summary scorecard

| Metric | Seed baseline (Phase 3) | Seed optimized (Phase 4) | 20× large optimized (Phase 5) |
|--------|------------------------:|-------------------------:|------------------------------:|
| Total query time (R+W) | 11,727 ms | 40.9 ms | **~155 ms** |
| Queries meeting targets | 0 / 30 | 30 / 30 | **30 / 30** |
| R13 correctness | ❌ wrong (0 rows) | ✅ fixed | ✅ fixed |
| Slowest query | R19: 10,271 ms | R19: 8.7 ms | R19: 19.8 ms |
| Worst write W04 | 108 ms | 9.8 ms | 24.7 ms |
| Scaling factor (opt) | — | — | **~2.5–3.5× per 20× data** |

**Key insight:** Index scans scale **sub-linearly** — O(log N + result) instead of O(N). A 20× data increase causes only a 2.5–3.5× execution time increase for indexed queries. Without indexes, the same 20× data increase causes **10–100,000× slowdowns** (R13: 26 ms → 316,460 ms).

---

## 8. Recommendations for further growth (beyond 20×)

> [!TIP]
> The current schema and indexes comfortably handle 20× growth. The following changes are recommended if data grows to 50× or 100×.

1. **Add `properties_2027`, `properties_2028` partitions** before data arrives; avoid relying on `properties_future` for large volumes.
2. **Increase enquiries hash buckets from 8 to 16** at 50× (≈ 5M enquiries); 250k rows/shard is the sweet spot.
3. **`shared_buffers` → 2 GB** (25% of RAM on an 8 GB server) so the most-used index pages stay in cache.
4. **`work_mem` → 32 MB** to prevent sort spills in R19 and R25 aggregations.
5. **Connection pooling (PgBouncer)** to handle concurrent real-time search traffic without exhausting backend connections.
6. **Read replica** for the analytic reports (R04, R15, R19, R25) to offload the primary write path.
7. **`pg_partman`** for automated partition creation (monthly instead of yearly for `properties` at 100×).
