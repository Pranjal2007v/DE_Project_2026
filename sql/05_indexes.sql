-- =====================================================================
-- sql/05_indexes.sql
-- Housing.com Property Search Database
-- Phase 4: Indexes for optimization
--
-- Apply AFTER the Phase 2 schema (sql/01_schema.sql) and data load
-- (sql/02_load_data.sql) are in place.
--
-- How to run:
--   psql -d <db> -f sql/05_indexes.sql
--
-- Design rationale is documented in docs/04_optimization_report.md.
-- Each index block names the query or queries it helps.
-- =====================================================================

SET search_path TO housing;

-- =====================================================================
-- GROUP A: Foreign-key indexes
-- PostgreSQL does NOT index FK columns automatically.
-- These eliminate the full sequential scans on the child tables seen
-- in R06, R07, R11, R12, R14, R17, R19, R21, R25, W02, W04, W05.
-- =====================================================================

-- A1: properties.listed_by  → speeds up R06 (owner dashboard), R07,
--     R14 (agent leaderboard), W02, W05 (owner's latest/oldest rental)
CREATE INDEX idx_properties_listed_by
    ON properties (listed_by);

-- A2: properties.locality_id → speeds up R01, R02, R04, R05, R15, R21
CREATE INDEX idx_properties_locality_id
    ON properties (locality_id);

-- A3: properties.project_id → speeds up R11 (project page listings), R09
CREATE INDEX idx_properties_project_id
    ON properties (project_id);

-- A4: enquiries.property_id → speeds up R06, R12, R17, R19, R25
CREATE INDEX idx_enquiries_property_id
    ON enquiries (property_id);

-- A5: enquiries.user_id → speeds up R12, R25
CREATE INDEX idx_enquiries_user_id
    ON enquiries (user_id);

-- A6: site_visits.property_id → speeds up R06, R07, R21
CREATE INDEX idx_site_visits_property_id
    ON site_visits (property_id);

-- A7: site_visits.user_id → speeds up R12
CREATE INDEX idx_site_visits_user_id
    ON site_visits (user_id);

-- A8: price_changes.property_id → speeds up R08
CREATE INDEX idx_price_changes_property_id
    ON price_changes (property_id);

-- A9: shortlists.property_id → speeds up R25
--     (shortlists PK is (user_id, property_id); the reverse direction is unindexed)
CREATE INDEX idx_shortlists_property_id
    ON shortlists (property_id);

-- =====================================================================
-- GROUP B: Composite covering indexes for the high-frequency search paths
-- =====================================================================

-- B1: Rent / sale search  (R01, R02, R05)
--   Filters: status, listing_type, locality_id, bhk, price, furnishing
--   Include columns fetched in SELECT to allow Index-Only Scans.
CREATE INDEX idx_prop_search_rent
    ON properties (locality_id, status, listing_type, bhk, price)
    INCLUDE (property_id, carpet_area_sqft, furnishing, available_from);

-- B2: Map view  (R05)
--   Filters: listing_type, status + bounding box on lat/lng
CREATE INDEX idx_prop_map
    ON properties (listing_type, status, latitude, longitude)
    INCLUDE (property_id, price, bhk);

-- B3: Status + date range  (R14, R20, W04)
--   R14 filters status IN ('SOLD','RENTED') and posted_at >= date.
--   W04 filters status = 'ACTIVE' and posted_at < cutoff.
--   R20 filters posted_at::date in a range.
CREATE INDEX idx_prop_status_posted
    ON properties (status, posted_at);

-- B4: Owner / agent query optimisation  (W02, W05)
--   The sub-select in W02/W05 needs max/min(property_id) for a given
--   listed_by + status + listing_type combination.
CREATE INDEX idx_prop_lister_status_type
    ON properties (listed_by, status, listing_type, property_id DESC);

-- B5: Price-drop alerts  (R08)
--   Filters: changed_at in June 2026 and new_price <= old_price * 0.9
CREATE INDEX idx_pc_changed_at
    ON price_changes (changed_at)
    INCLUDE (property_id, old_price, new_price);

-- B6: Lead follow-up  (R12)
--   Filters: enquiries.created_at in June 2026
CREATE INDEX idx_enq_created_at
    ON enquiries (created_at)
    INCLUDE (enquiry_id, property_id, user_id);

-- B7: Owner nudges  (R17) – active properties posted before cutoff
CREATE INDEX idx_prop_active_posted
    ON properties (status, posted_at)
    WHERE status = 'ACTIVE';

-- B8: Fraud check  (R18) – active rows grouped by lister + locality + area + floor + BHK
CREATE INDEX idx_prop_active_fraud
    ON properties (listed_by, locality_id, carpet_area_sqft, floor_no, bhk)
    WHERE status = 'ACTIVE';

-- B9: Site-visit schedule  (R07)
--   scheduled_at::date = '2026-07-01' wraps the column in a cast, which
--   blocks a plain index. Store the extracted date as an expression index.
CREATE INDEX idx_sv_scheduled_date
    ON site_visits ((scheduled_at::date));

-- B10: Pagination cursor support  (R22)
--   OFFSET 50000 must sort all 120k rows; a covering index on (posted_at DESC)
--   lets PostgreSQL walk the index instead of sorting.
CREATE INDEX idx_prop_posted_desc
    ON properties (posted_at DESC)
    INCLUDE (property_id, listed_by, listing_type, status, price);

-- B11: Site-visit rating  (R21)
--   Only completed visits with a rating are needed.
CREATE INDEX idx_sv_rated
    ON site_visits (property_id, feedback_rating)
    WHERE feedback_rating IS NOT NULL;

-- B12: Price-trend analysis  (R04)
--   Filter: locality_id, listing_type = 'SALE', property_type = 'APARTMENT',
--   EXTRACT(YEAR FROM posted_at) = 2026.
CREATE INDEX idx_prop_sale_apt_posted
    ON properties (locality_id, listing_type, property_type, posted_at)
    INCLUDE (price, carpet_area_sqft)
    WHERE listing_type = 'SALE' AND property_type = 'APARTMENT';

-- B13: Locality → city lookup  (R19, R25, R15)
--   Speeds up the join properties → localities filtered by city_id.
CREATE INDEX idx_localities_city_id
    ON localities (city_id);

-- =====================================================================
-- Refresh planner statistics so the new indexes are used immediately
-- =====================================================================
ANALYZE;
