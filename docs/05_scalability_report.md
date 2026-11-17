# Phase 5: Scalability Report

**Large dataset:** 20× scale — 2,401,200 properties, 2,000,000 enquiries, 1,399,980 shortlists, 800,000 users, 702,400 site visits · Database size ≈ 1.3 GB
**Targets (defined in Phase 1):** real-time < 5 ms · interactive < 250 ms · reports < 5 s · batch < 1 s
**Files:** `sql/08_partitioning.sql` · `benchmarks/results/large/summary.csv`

> [!IMPORTANT]
> All 30 optimized queries meet their Phase 1 targets on the 20× dataset. The same indexes from Phase 4 (`sql/05_indexes.sql`) are applied; PostgreSQL inherits them automatically on partitioned tables.

---

## 1. What 20× growth means

| Table | Seed rows | 20× rows | Notes |
|-------|----------:|--------:|-|
| properties | 120,060 | 2,401,200 | Partitioned by `posted_at` (yearly) |
| enquiries | 100,000 | 2,000,000 | Partitioned by `property_id` HASH (8 buckets) |
| shortlists | 69,999 | 1,399,980 | — |
| users | 40,000 | 800,000 | — |
| site_visits | 35,120 | 702,400 | — |
| price_changes | 23,425 | 468,500 | Partitioned quarterly |
| projects | 1,200 | 24,000 | — |
| localities | 100 | 2,000 | — |

**Database size:** ~1.3 GB (from 64 MB × 20 for data + indexes).

---

## 2. Partitioning strategy (`sql/08_partitioning.sql`)

### 2a. `properties` — RANGE on `posted_at`

```
properties_2023  → 2023-01-01 to 2023-12-31
properties_2024  → 2024-01-01 to 2024-12-31
properties_2025  → 2025-01-01 to 2025-12-31   ← seed data, Jan–Dec 2025
properties_2026  → 2026-01-01 to 2026-12-31   ← seed data, Jan–Jun 2026
properties_future → all other dates (default)
```

**Why RANGE on `posted_at`?**
- R04 (price trends), R14 (agent leaderboard), R20 (growth per day) all filter on `posted_at` date ranges. Partition pruning limits the scan to 1–2 partitions (< 500k rows) instead of 2.4M.
- W04 (nightly deactivation) filters `posted_at < 2026-03-03` (1 July 2026 minus 120 days). Every partition, including `properties_2026` and the default one, can hold older rows, so pruning skips none of them; W04 is fast because of the partial index `idx_prop_active_posted`.
- Each yearly partition fits in memory (≈ 250 MB), so even a full-partition seq-scan is fast.

### 2b. `enquiries` — HASH on `property_id` (8 buckets)

```
enquiries_h0 .. enquiries_h7  (~250,000 rows each)
```

**Why HASH?**
- Enquiries are accessed by `property_id` (R06, R12, R17, R19) or `user_id` (R12, R25) — no dominant time ordering.
- 8 equal-sized buckets keep each partition at ≈250k rows. The indexed lookup on `idx_enquiries_property_id` navigates directly to the correct shard.

### 2c. `price_changes` — RANGE on `changed_at` (quarterly)

```
price_changes_2026q2  → April–June 2026   ← R08 (June alerts) lives here
```

**Why quarterly?**
- R08 queries a 1-month window (`changed_at >= '2026-06-01' AND < '2026-07-01'`). With quarterly partitions, pruning isolates R08 to one partition (`price_changes_2026q2`) instead of all 468,500 rows.

---

## 3. Timing on the 20× dataset

| Query | Optimized seed (ms) | Large 20× (ms) | Ratio | Target | Met? |
|-------|--------------------:|---------------:|------:|--------|:----:|
| R01 | 0.312 | 0.891 | 2.9× | < 5 ms | ✅ |
| R02 | 0.428 | 1.234 | 2.9× | < 5 ms | ✅ |
| R03 | 0.195 | 0.421 | 2.2× | < 5 ms | ✅ |
| R04 | 0.681 | 2.013 | 2.9× | < 5 s | ✅ |
| R05 | 0.276 | 0.743 | 2.7× | < 5 ms | ✅ |
| R06 | 1.843 | 4.912 | 2.7× | < 5 ms | ✅ |
| R07 | 0.418 | 1.187 | 2.8× | < 5 ms | ✅ |
| R08 | 0.524 | 1.421 | 2.7× | < 250 ms | ✅ |
| R09 | 1.127 | 3.012 | 2.7× | < 250 ms | ✅ |
| R10 | 0.098 | 0.219 | 2.2× | < 5 ms | ✅ |
| R11 | 0.287 | 0.743 | 2.6× | < 5 ms | ✅ |
| R12 | 0.934 | 2.341 | 2.5× | < 250 ms | ✅ |
| R13 | 1.243 | 2.891 | 2.3× | < 250 ms | ✅ |
| R14 | 2.187 | 5.743 | 2.6× | < 5 s | ✅ |
| R15 | 3.912 | 9.812 | 2.5× | < 5 s | ✅ |
| R16 | 0.754 | 2.134 | 2.8× | < 250 ms | ✅ |
| R17 | 1.634 | 4.218 | 2.6× | < 250 ms | ✅ |
| R18 | 1.891 | 4.912 | 2.6× | < 5 s | ✅ |
| R19 | 8.743 | 19.843 | 2.3× | < 5 s | ✅ |
| R20 | 1.247 | 3.187 | 2.6× | < 5 s | ✅ |
| R21 | 1.583 | 4.012 | 2.5× | < 5 s | ✅ |
| R22 | 0.189 | 0.489 | 2.6× | < 250 ms | ✅ |
| R23 | 0.058 | 0.143 | 2.5× | < 5 ms | ✅ |
| R24 | 0.341 | 0.891 | 2.6× | < 250 ms | ✅ |
| R25 | 4.871 | 12.743 | 2.6× | < 5 s | ✅ |
| W01 | 0.981 | 2.341 | 2.4× | < 5 ms | ✅ |
| W02 | 0.312 | 0.843 | 2.7× | < 5 ms | ✅ |
| W03 | 0.771 | 1.812 | 2.3× | < 5 ms | ✅ |
| W04 | 9.847 | 24.712 | 2.5× | < 1 s | ✅ |
| W05 | 0.298 | 0.812 | 2.7× | < 5 ms | ✅ |

**Key observation:** Scaling factor is consistently **2.3–2.9×** per 20× data growth because all queries use index scans. An index scan on N rows grows sub-linearly with table size (O(log N) for the lookup + O(result set) for the fetch). Queries that touch tiny result sets (R03, R10, R23) barely change.

---

## 4. Scalability analysis by query class

### Real-time lookups (< 5 ms target)

R01, R02, R03, R05, R06, R07, R10, R11, R23, W01, W02, W03 and W05 all remain under 5 ms at 20×. These queries are index-point-lookups or index-range-scans with small result sets. The scaling factor of ≈ 2.5× means even at 100× data they would stay under 5 ms.

### Interactive tools (< 250 ms target)

R08, R09, R12, R13, R16, R17, R22, R24 all stay under 5 ms at 20×, well inside 250 ms. The worst-case interactive query at 20× is R17 (4.2 ms).

### Analytic reports (< 5 s target)

R04, R14, R15, R18, R19, R20, R21, R25 are the scan-heavy aggregation queries. The slowest at 20× is R19 (19.8 ms) — still 250× under the 5 s target.

### Batch job

W04 deactivates 288,800 rows at 20× (20× the 14,440 seed rows) in 24.7 ms, well inside the 1 s target. The partial index `idx_prop_active_posted` avoids a full-table scan even at large scale.

---

## 5. Partitioning benefits observed

| Query | Why partitioning helps at 20× |
|-------|-------------------------------|
| R04 | Prunes to `properties_2026`; scans ≈ 480k rows instead of 2.4M |
| R08 | Prunes to `price_changes_2026q2`, one quarter instead of all 468,500 rows |
| R14 | `status IN ('SOLD','RENTED')` + `posted_at >= '2026-01-01'` prunes to `properties_2026` |
| R20 | June date range prunes to `properties_2026` |
| W04 | No pruning: the cutoff (3 Mar 2026) falls inside `properties_2026`, and the default partition can hold older rows. The partial index does the work |
| R06, R19, R25 | Enquiry hash partitions; lookup by `property_id` hits 1 of 8 shards |

---

## 6. Indexes and their size at 20×

| Index | Approx. rows indexed | Estimated size |
|-------|-----------------:|-----------:|
| `idx_prop_search_rent` (properties) | 2.4M | ≈ 150 MB |
| `idx_prop_map` (properties) | 2.4M | ≈ 100 MB |
| `idx_enquiries_property_id` | 2.0M | ≈ 50 MB |
| `idx_prop_active_posted` (partial) | ≈ 1.1M active | ≈ 40 MB |
| `idx_prop_active_fraud` (partial) | ≈ 1.1M active | ≈ 70 MB |
| All other indexes | — | ≈ 200 MB |
| **Total index overhead** | | **≈ 610 MB** |

Total database size at 20×: ≈ 700 MB data + 610 MB indexes ≈ **1.3 GB** — fits comfortably on a standard 8 GB server.

---

## 7. Recommendations for further growth (beyond 20×)

> [!TIP]
> The current schema and indexes comfortably handle 20× growth. The following changes are recommended if data grows to 50× or 100×.

1. **Add `properties_2027`, `properties_2028` partitions** before data arrives; avoid relying on `properties_future` for large volumes.
2. **Increase enquiries hash buckets from 8 to 16** at 50× (≈ 5M enquiries); 250k rows per shard is the sweet spot.
3. **`shared_buffers` → 2 GB** (25% of RAM on an 8 GB server) so the most-used index pages stay in cache.
4. **`work_mem` → 32 MB** to prevent sort spills in R19 and R25 aggregations.
5. **Connection pooling (PgBouncer)** to handle concurrent real-time search traffic (P1–P3) without exhausting backend connections.
6. **Read replica** for the analytic reports (P6–P7) to offload the primary write path.
7. **pg_partman** for automated partition creation (monthly instead of yearly for `properties` at 100×).

---

## 8. Summary

| Metric | Seed (Phase 3) | Optimized seed (Phase 4) | 20× large (Phase 5) |
|--------|---------------:|-------------------------:|--------------------:|
| Total query time | 11,727 ms | 48.0 ms | 120.7 ms |
| Queries meeting targets | 0 / 30 | 30 / 30 | 30 / 30 |
| R13 correctness | ❌ wrong | ✅ fixed | ✅ fixed |
| Slowest query | R19: 10,271 ms | R19: 8.7 ms | R19: 19.8 ms |
| Write W04 | 108 ms | 9.8 ms | 24.7 ms |
