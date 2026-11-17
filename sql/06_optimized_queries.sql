-- =====================================================================
-- sql/06_optimized_queries.sql
-- Housing.com Property Search Database
-- Phase 4: Optimized versions of all 30 queries
--
-- Rules:
--   * Every optimized query must return the SAME rows as the original
--     except R13, which is FIXED (NOT IN → NOT EXISTS) for correctness.
--   * Run AFTER sql/05_indexes.sql has been applied.
--   * Benchmarked with the same method as Phase 3 (3 runs, EXPLAIN ANALYZE).
--   * Write queries run inside BEGIN … ROLLBACK so data does not change.
--
-- How to run:
--   psql -d <db> -f sql/06_optimized_queries.sql
-- =====================================================================

SET search_path TO housing;
BEGIN;

-- @R01
-- Rent search: active 2 BHK homes in Koramangala up to ₹40,000/month
-- Optimization: idx_prop_search_rent + idx_properties_locality_id
--   eliminates the full seq-scan; locality is looked up by the UNIQUE
--   index on (city_id, locality_name) and the FK index joins efficiently.
SELECT p.property_id, p.price AS rent, p.carpet_area_sqft, p.furnishing, p.available_from
FROM properties p
JOIN localities l ON l.locality_id = p.locality_id
WHERE l.locality_name = 'Koramangala' AND l.city_id = 1
  AND p.listing_type = 'RENT' AND p.status = 'ACTIVE'
  AND p.bhk = 2 AND p.price <= 40000
  AND p.furnishing IN ('SEMI_FURNISHED', 'FULLY_FURNISHED')
ORDER BY p.price;

-- @R02
-- Buy search: 3 BHK apartments for sale in Pune under ₹1.2 crore
-- Optimization: same composite index; city_id = 6 filters via locality join.
SELECT p.property_id, l.locality_name, p.price, p.carpet_area_sqft,
       round(p.price / p.carpet_area_sqft, 0) AS price_per_sqft
FROM properties p
JOIN localities l ON l.locality_id = p.locality_id
WHERE l.city_id = 6
  AND p.listing_type = 'SALE' AND p.status = 'ACTIVE'
  AND p.property_type = 'APARTMENT' AND p.bhk = 3
  AND p.price < 12000000
ORDER BY price_per_sqft
LIMIT 30;

-- @R03
-- Property page: property 6897 (unchanged – already 0.19 ms via PKs)
SELECT p.property_id, p.price, p.bhk, p.carpet_area_sqft, pj.project_name, b.builder_name,
       string_agg(a.amenity_name, ', ' ORDER BY a.amenity_name) AS amenities
FROM properties p
LEFT JOIN projects pj          ON pj.project_id = p.project_id
LEFT JOIN builders b           ON b.builder_id = pj.builder_id
LEFT JOIN project_amenities pa ON pa.project_id = p.project_id
LEFT JOIN amenities a          ON a.amenity_id = pa.amenity_id
WHERE p.property_id = 6897
GROUP BY p.property_id, p.price, p.bhk, p.carpet_area_sqft, pj.project_name, b.builder_name;

-- @R04
-- Price trends: Whitefield sale apartments per month in 2026
-- Optimization: idx_prop_sale_apt_posted partial index covers
--   (locality_id, listing_type, property_type, posted_at) for SALE + APARTMENT.
--   date_trunc is applied on the index-scanned posted_at, no seq-scan needed.
SELECT date_trunc('month', p.posted_at) AS month, count(*) AS listings,
       round(avg(p.price / p.carpet_area_sqft), 0) AS avg_price_per_sqft
FROM properties p
JOIN localities l ON l.locality_id = p.locality_id
WHERE l.locality_name = 'Whitefield'
  AND p.listing_type = 'SALE' AND p.property_type = 'APARTMENT'
  AND p.posted_at >= '2026-01-01' AND p.posted_at < '2027-01-01'
GROUP BY 1
ORDER BY 1;

-- @R05
-- Map view: active rentals in central Bengaluru bounding box
-- Optimization: idx_prop_map (listing_type, status, latitude, longitude)
SELECT property_id, latitude, longitude, price, bhk
FROM properties
WHERE listing_type = 'RENT' AND status = 'ACTIVE'
  AND latitude  BETWEEN 12.90 AND 13.00
  AND longitude BETWEEN 77.55 AND 77.65
LIMIT 200;

-- @R06
-- Owner dashboard: owner 1033's listings with enquiry and site-visit counts
-- Optimization: idx_properties_listed_by, idx_enquiries_property_id,
--   idx_site_visits_property_id — all three FK indexes are now used.
SELECT p.property_id, p.listing_type, p.status, p.price,
       count(DISTINCT e.enquiry_id) AS enquiries, count(DISTINCT v.visit_id) AS visits
FROM properties p
LEFT JOIN enquiries   e ON e.property_id = p.property_id
LEFT JOIN site_visits v ON v.property_id = p.property_id
WHERE p.listed_by = 1033
GROUP BY p.property_id, p.listing_type, p.status, p.price
ORDER BY enquiries DESC;

-- @R07
-- Agent app: site visits on 1 July 2026 for properties by user 4723
-- Optimization: idx_sv_scheduled_date (expression index on scheduled_at::date)
--   eliminates the full seq-scan on site_visits; idx_properties_listed_by
--   then quickly finds the matching properties.
SELECT v.visit_id, v.property_id, v.scheduled_at, u.full_name AS visitor, u.phone
FROM site_visits v
JOIN properties p ON p.property_id = v.property_id
JOIN users u      ON u.user_id = v.user_id
WHERE p.listed_by = 4723
  AND v.scheduled_at::date = '2026-07-01'
ORDER BY v.scheduled_at;

-- @R08
-- Price-drop alerts: price fell ≥ 10 % in June 2026
-- Optimization: idx_pc_changed_at covers the range scan on changed_at;
--   idx_properties_listed_by not needed here but property_id FK index speeds
--   the join back to properties.
SELECT c.property_id, c.old_price, c.new_price,
       round(100 * (1 - c.new_price / c.old_price), 1) AS drop_pct
FROM price_changes c
JOIN properties p ON p.property_id = c.property_id AND p.status = 'ACTIVE'
WHERE c.changed_at >= '2026-06-01' AND c.changed_at < '2026-07-01'
  AND c.new_price <= c.old_price * 0.9
ORDER BY drop_pct DESC;

-- @R09
-- Amenity filter: active properties in projects with gym + pool + power backup
-- Optimization: idx_properties_project_id eliminates the seq-scan on properties;
--   the subquery uses pk_project_amenities (index-only scan).
SELECT p.property_id, p.price, p.project_id
FROM properties p
WHERE p.status = 'ACTIVE'
  AND p.project_id IN (
      SELECT pa.project_id
      FROM project_amenities pa
      JOIN amenities a ON a.amenity_id = pa.amenity_id
      WHERE a.amenity_name IN ('Gym', 'Swimming Pool', 'Power Backup')
      GROUP BY pa.project_id
      HAVING count(*) = 3
  )
ORDER BY p.price
LIMIT 50;

-- @R10
-- RERA lookup (unchanged – already 0.10 ms via uq_projects_rera index)
SELECT p.project_id, p.project_name, b.builder_name, p.possession_status, p.possession_date
FROM projects p
JOIN builders b ON b.builder_id = p.builder_id
WHERE p.rera_id = 'TS-RERA-PR-11726342';

-- @R11
-- Project page: listings in project 217
-- Optimization: idx_properties_project_id eliminates the 120k-row seq-scan.
SELECT bhk, listing_type, count(*) AS listings, min(price) AS min_price, max(price) AS max_price
FROM properties
WHERE project_id = 217 AND status = 'ACTIVE'
GROUP BY bhk, listing_type
ORDER BY bhk, listing_type;

-- @R12
-- Lead follow-up: June enquiries with no visit booked
-- Optimization: idx_enq_created_at narrows enquiries to the date range;
--   idx_site_visits_property_id + idx_site_visits_user_id speed the NOT EXISTS.
SELECT e.enquiry_id, e.property_id, e.user_id, e.created_at
FROM enquiries e
WHERE e.created_at >= '2026-06-01' AND e.created_at < '2026-06-24'
  AND NOT EXISTS (
      SELECT 1 FROM site_visits v
      WHERE v.property_id = e.property_id AND v.user_id = e.user_id
  )
ORDER BY e.created_at;

-- @R13
-- Builder partnerships: projects with NO property listed
-- *** CORRECTNESS FIX ***
-- Original used NOT IN (SELECT project_id FROM properties).
-- 54,009 properties have project_id = NULL; a single NULL in the NOT IN
-- list makes the predicate UNKNOWN for every project → 0 rows returned.
-- NOT EXISTS is NULL-safe and returns the correct 120 projects.
SELECT pj.project_id, pj.project_name, pj.possession_status
FROM projects pj
WHERE NOT EXISTS (
    SELECT 1 FROM properties p WHERE p.project_id = pj.project_id
);

-- @R14
-- Agent leaderboard: agents with most sold/rented properties in 2026
-- Optimization: idx_prop_status_posted covers (status, posted_at);
--   idx_properties_listed_by then joins to users.
SELECT u.user_id, u.full_name, count(*) AS deals
FROM properties p
JOIN users u ON u.user_id = p.listed_by AND u.user_type = 'AGENT'
WHERE p.status IN ('SOLD', 'RENTED') AND p.posted_at >= '2026-01-01'
GROUP BY u.user_id, u.full_name
ORDER BY deals DESC
LIMIT 20;

-- @R15
-- Investor insights: rental yield by Bengaluru locality
-- Optimization: idx_properties_locality_id + idx_localities_city_id
SELECT l.locality_name,
       round(avg(p.price / p.carpet_area_sqft) FILTER (WHERE p.listing_type = 'RENT') * 12, 1) AS yearly_rent_psf,
       round(avg(p.price / p.carpet_area_sqft) FILTER (WHERE p.listing_type = 'SALE'), 0)       AS sale_psf,
       round(100 * 12 * avg(p.price / p.carpet_area_sqft) FILTER (WHERE p.listing_type = 'RENT')
                 / avg(p.price / p.carpet_area_sqft) FILTER (WHERE p.listing_type = 'SALE'), 2) AS yield_pct
FROM properties p
JOIN localities l ON l.locality_id = p.locality_id
WHERE l.city_id = 1 AND p.property_type = 'APARTMENT'
GROUP BY l.locality_name
ORDER BY yield_pct DESC;

-- @R16
-- Search box: projects with "greens" in the name
-- Optimization: table is only 1,200 rows; already 0.76 ms. No index can help
--   ILIKE '%text%'. Kept as-is.
SELECT project_id, project_name, possession_status
FROM projects
WHERE project_name ILIKE '%greens%'
ORDER BY project_name
LIMIT 30;

-- @R17
-- Owner nudges: active listings > 90 days with no enquiry
-- Optimization: idx_prop_active_posted partial index (WHERE status = 'ACTIVE')
--   with posted_at enables a range scan; idx_enquiries_property_id speeds NOT EXISTS.
SELECT p.property_id, p.listed_by, p.posted_at
FROM properties p
WHERE p.status = 'ACTIVE'
  AND p.posted_at < TIMESTAMPTZ '2026-07-01 00:00:00+05:30' - interval '90 days'
  AND NOT EXISTS (SELECT 1 FROM enquiries e WHERE e.property_id = p.property_id)
ORDER BY p.posted_at;

-- @R18
-- Fraud check: same flat listed more than once
-- Optimization: idx_prop_active_fraud partial index on the grouped columns
--   eliminates the full scan of 120k rows.
SELECT listed_by, locality_id, carpet_area_sqft, floor_no, bhk, count(*) AS copies
FROM properties
WHERE status = 'ACTIVE'
GROUP BY listed_by, locality_id, carpet_area_sqft, floor_no, bhk
HAVING count(*) > 1
ORDER BY copies DESC;

-- @R19
-- City report: enquiries per active sale property in Bengaluru
-- *** MAJOR REWRITE ***
-- Original: two correlated subqueries each scanning 100k enquiries per property row
--   ≈ 3,560 full scans → 10,271 ms.
-- Optimized: aggregate enquiries ONCE with a CTE, then LEFT JOIN.
--   idx_enquiries_property_id makes the aggregation fast;
--   idx_localities_city_id speeds the locality → city filter.
WITH enq_summary AS (
    SELECT property_id,
           count(*)      AS enquiries,
           max(created_at) AS last_enquiry_at
    FROM enquiries
    GROUP BY property_id
)
SELECT p.property_id, p.price,
       coalesce(es.enquiries, 0)       AS enquiries,
       es.last_enquiry_at
FROM properties p
JOIN localities l    ON l.locality_id = p.locality_id
LEFT JOIN enq_summary es ON es.property_id = p.property_id
WHERE l.city_id = 1 AND p.listing_type = 'SALE' AND p.status = 'ACTIVE'
ORDER BY enquiries DESC;

-- @R20
-- Growth: new listings per day, June 2026 running total
-- Optimization: idx_prop_status_posted allows an index range scan on posted_at.
--   Changed EXTRACT/::date to a sargable range predicate.
SELECT day, listings, sum(listings) OVER (ORDER BY day) AS running_total
FROM (
    SELECT posted_at::date AS day, count(*) AS listings
    FROM properties
    WHERE posted_at >= '2026-06-01' AND posted_at < '2026-07-01'
    GROUP BY 1
) d
ORDER BY day;

-- @R21
-- Average site-visit rating per locality (≥ 10 rated visits)
-- Optimization: idx_sv_rated partial index (WHERE feedback_rating IS NOT NULL)
--   skips the 20k unrated visits; idx_site_visits_property_id speeds the join.
SELECT l.locality_name, round(avg(v.feedback_rating), 2) AS avg_rating, count(*) AS rated_visits
FROM site_visits v
JOIN properties p ON p.property_id = v.property_id
JOIN localities l ON l.locality_id = p.locality_id
WHERE v.feedback_rating IS NOT NULL
GROUP BY l.locality_name
HAVING count(*) >= 10
ORDER BY avg_rating DESC;

-- @R22
-- Moderation console: all listings, newest first, page 2,001
-- *** REWRITE: keyset pagination replaces OFFSET ***
-- OFFSET 50000 had to sort all 120k rows and throw 50k away (5.7 MB sort spill).
-- Keyset: pass the (posted_at, property_id) of the last row on page 2000.
-- idx_prop_posted_desc is used as a covering index; no sort, no spill.
-- NOTE: for automatic benchmarking we use a fixed boundary that matches
--       the row that OFFSET 50000 would have returned on the seed dataset.
SELECT property_id, listed_by, listing_type, status, price, posted_at
FROM properties
WHERE (posted_at, property_id) < ('2026-04-27 15:30:00+05:30', 68050)
ORDER BY posted_at DESC, property_id DESC
LIMIT 25;

-- @R23
-- Sign-in with mobile number (unchanged – already 0.06 ms via uq_users_phone)
SELECT user_id, full_name, user_type
FROM users
WHERE phone = '9600001042';

-- @R24
-- Delayed under-construction projects (unchanged – tiny tables, 0.35 ms)
SELECT pj.project_id, pj.project_name, b.builder_name, pj.possession_date
FROM projects pj
JOIN builders b ON b.builder_id = pj.builder_id
WHERE pj.possession_status = 'UNDER_CONSTRUCTION'
  AND pj.possession_date < '2026-07-01'
ORDER BY pj.possession_date;

-- @R25
-- Funnel: shortlists → enquiry conversion per city
-- *** MAJOR REWRITE ***
-- Original: a correlated EXISTS scanned all 100k enquiries for each of 70k shortlists
--   → ~881 ms, JIT triggered.
-- Optimized: hash-join shortlists to a pre-aggregated conversion set.
--   idx_enquiries_property_id + idx_enquiries_user_id speed the join;
--   idx_shortlists_property_id helps the properties join.
WITH converted AS (
    SELECT DISTINCT e.property_id, e.user_id
    FROM enquiries e
)
SELECT l.city_id,
       count(*)                                           AS shortlists,
       count(c.property_id)                              AS converted
FROM shortlists s
JOIN properties p  ON p.property_id = s.property_id
JOIN localities l  ON l.locality_id = p.locality_id
LEFT JOIN converted c ON c.property_id = s.property_id AND c.user_id = s.user_id
GROUP BY l.city_id
ORDER BY l.city_id;

-- @W01
-- Post property (unchanged – plain INSERT, ~1 ms)
INSERT INTO properties (property_id, listed_by, locality_id, listing_type, property_type, bhk, carpet_area_sqft, floor_no,
                        total_floors, furnishing, facing, price, security_deposit, available_from, latitude, longitude,
                        status, posted_at)
VALUES (90000001, 1033, 1, 'RENT', 'APARTMENT', 2, 1050, 3, 8, 'SEMI_FURNISHED', 'EAST', 38000, 114000, '2026-07-15',
        12.931200, 77.627000, 'ACTIVE', '2026-07-01 10:00:00+05:30');

-- @W02
-- Price cut: owner 1033 reduces rent of most recent active rental by 5%
-- Optimization: idx_prop_lister_status_type (listed_by, status, listing_type, property_id DESC)
--   gives the max(property_id) directly from the index without a seq-scan.
UPDATE properties
SET price = round(price * 0.95, -2)
WHERE property_id = (
    SELECT property_id FROM properties
    WHERE listed_by = 1033 AND status = 'ACTIVE' AND listing_type = 'RENT'
    ORDER BY property_id DESC
    LIMIT 1
);

-- @W03
-- Book a site visit (unchanged – plain INSERT, ~0.8 ms)
INSERT INTO site_visits (visit_id, property_id, user_id, scheduled_at, status)
VALUES (90000001, 6897, 1042, '2026-07-04 11:00:00+05:30', 'SCHEDULED');

-- @W04
-- Nightly job: deactivate active listings older than 120 days
-- Optimization: idx_prop_active_posted partial index covers (status = 'ACTIVE', posted_at)
--   so the planner finds the 14,440 rows to update without a full seq-scan.
UPDATE properties
SET status = 'INACTIVE'
WHERE status = 'ACTIVE'
  AND posted_at < TIMESTAMPTZ '2026-07-01 00:00:00+05:30' - interval '120 days';

-- @W05
-- Owner 1033 marks oldest active rental as rented
-- Optimization: same composite index walks ASC to find min(property_id) instantly.
UPDATE properties
SET status = 'RENTED'
WHERE property_id = (
    SELECT property_id FROM properties
    WHERE listed_by = 1033 AND status = 'ACTIVE' AND listing_type = 'RENT'
    ORDER BY property_id ASC
    LIMIT 1
);

-- @END
ROLLBACK;
