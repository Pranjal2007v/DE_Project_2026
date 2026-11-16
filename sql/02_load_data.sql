-- =====================================================================
-- sql/02_load_data.sql
-- Phase 2: load the 12 seed CSV files (parents before children).
--
-- Run from the project root (the folder that contains seed_data/):
--     psql -d <your_database> -f sql/01_schema.sql
--     psql -d <your_database> -f sql/02_load_data.sql
--
-- For the large dataset (Phase 5) only change the folder name seed_data -> large_data.
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path TO housing;
SET timezone TO 'Asia/Kolkata';

BEGIN;

-- level 0: no foreign keys
\copy cities            FROM 'seed_data/cities.csv'            WITH (FORMAT csv, HEADER true)
\copy builders          FROM 'seed_data/builders.csv'          WITH (FORMAT csv, HEADER true)
\copy amenities         FROM 'seed_data/amenities.csv'         WITH (FORMAT csv, HEADER true)
\copy users             FROM 'seed_data/users.csv'             WITH (FORMAT csv, HEADER true)

-- level 1: need cities / builders
\copy localities        FROM 'seed_data/localities.csv'        WITH (FORMAT csv, HEADER true)

-- level 2: need localities + builders
\copy projects          FROM 'seed_data/projects.csv'          WITH (FORMAT csv, HEADER true)

-- level 3: need projects + amenities
\copy project_amenities FROM 'seed_data/project_amenities.csv' WITH (FORMAT csv, HEADER true)

-- level 4: need users + projects + localities
\copy properties        FROM 'seed_data/properties.csv'        WITH (FORMAT csv, HEADER true)

-- level 5: need properties (+ users)
\copy price_changes     FROM 'seed_data/price_changes.csv'     WITH (FORMAT csv, HEADER true)
\copy enquiries         FROM 'seed_data/enquiries.csv'         WITH (FORMAT csv, HEADER true)
\copy site_visits       FROM 'seed_data/site_visits.csv'       WITH (FORMAT csv, HEADER true)
\copy shortlists        FROM 'seed_data/shortlists.csv'        WITH (FORMAT csv, HEADER true)

COMMIT;

-- fresh planner statistics (needed before any timing in Phase 3)
ANALYZE;

-- =====================================================================
-- VERIFICATION 1: row counts must match the seed files
-- =====================================================================
SELECT t.table_name, t.loaded, t.expected,
       CASE WHEN t.loaded = t.expected THEN 'OK' ELSE 'MISMATCH' END AS result
FROM (
    SELECT 'cities' AS table_name,            (SELECT count(*) FROM cities)            AS loaded,     10 AS expected UNION ALL
    SELECT 'localities',                      (SELECT count(*) FROM localities),                     100 UNION ALL
    SELECT 'builders',                        (SELECT count(*) FROM builders),                       150 UNION ALL
    SELECT 'projects',                        (SELECT count(*) FROM projects),                      1200 UNION ALL
    SELECT 'amenities',                       (SELECT count(*) FROM amenities),                       15 UNION ALL
    SELECT 'project_amenities',               (SELECT count(*) FROM project_amenities),             6806 UNION ALL
    SELECT 'users',                           (SELECT count(*) FROM users),                        40000 UNION ALL
    SELECT 'properties',                      (SELECT count(*) FROM properties),                  120060 UNION ALL
    SELECT 'price_changes',                   (SELECT count(*) FROM price_changes),                23425 UNION ALL
    SELECT 'enquiries',                       (SELECT count(*) FROM enquiries),                   100000 UNION ALL
    SELECT 'site_visits',                     (SELECT count(*) FROM site_visits),                  35120 UNION ALL
    SELECT 'shortlists',                      (SELECT count(*) FROM shortlists),                   69999
) t
ORDER BY t.table_name;

-- =====================================================================
-- VERIFICATION 2: integrity checks (every "violations" value must be 0,
-- except the two checks marked DATA-QUALITY which document real problems)
-- =====================================================================
SELECT 'IC1  property in a project has the same locality as the project' AS check_name,
       count(*) AS violations
FROM properties p JOIN projects j ON j.project_id = p.project_id
WHERE p.locality_id <> j.locality_id
UNION ALL
SELECT 'IC2  properties.price equals the newest price_changes.new_price',
       count(*)
FROM properties p
JOIN (SELECT DISTINCT ON (property_id) property_id, new_price
      FROM price_changes
      ORDER BY property_id, changed_at DESC, change_id DESC) lc USING (property_id)
WHERE p.price <> lc.new_price
UNION ALL
SELECT 'IC3  only OWNER or AGENT users list properties',
       count(*)
FROM properties p JOIN users u ON u.user_id = p.listed_by
WHERE u.user_type NOT IN ('OWNER', 'AGENT')
UNION ALL
SELECT 'IC4  only SEEKER users enquire, visit or shortlist',
       (SELECT count(*) FROM enquiries   e JOIN users u USING (user_id) WHERE u.user_type <> 'SEEKER')
     + (SELECT count(*) FROM site_visits v JOIN users u USING (user_id) WHERE u.user_type <> 'SEEKER')
     + (SELECT count(*) FROM shortlists  s JOIN users u USING (user_id) WHERE u.user_type <> 'SEEKER')
UNION ALL
SELECT 'IC5  a price change never predates the listing',
       count(*)
FROM price_changes c JOIN properties p USING (property_id)
WHERE c.changed_at < p.posted_at
UNION ALL
SELECT 'IC6  an enquiry never predates the listing',
       count(*)
FROM enquiries e JOIN properties p USING (property_id)
WHERE e.created_at < p.posted_at
UNION ALL
SELECT 'IC7  every old_price >= current price (all recorded changes are drops)',
       count(*)
FROM properties p
JOIN price_changes c USING (property_id)
WHERE c.old_price < p.price
UNION ALL
SELECT 'IC8  DATA-QUALITY: lister account created AFTER the listing was posted',
       count(*)
FROM properties p JOIN users u ON u.user_id = p.listed_by
WHERE p.posted_at < u.created_at
UNION ALL
SELECT 'IC9  DATA-QUALITY: rows dated after 30 Jun 2026 (properties.posted_at)',
       count(*)
FROM properties
WHERE posted_at >= TIMESTAMPTZ '2026-07-01 00:00:00+05:30'
ORDER BY 1;

-- Which indexes exist now? (should be only PK / UNIQUE ones)
SELECT tablename, indexname
FROM pg_indexes
WHERE schemaname = 'housing'
ORDER BY tablename, indexname;