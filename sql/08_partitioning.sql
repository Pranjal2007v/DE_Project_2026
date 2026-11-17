-- =====================================================================
-- sql/08_partitioning.sql
-- Housing.com Property Search Database
-- Phase 5: Table partitioning for the 20× large dataset
--
-- Scenario: 120,060 → 2,401,200 properties (20×), other tables scale similarly.
-- Expected database size: ~1.3 GB (from 64 MB × 20).
--
-- Strategy:
--   - RANGE partition `properties` by `posted_at` (yearly slabs 2023–2027 + default)
--   - HASH partition `enquiries` into 8 shards (access is by property_id / user_id,
--     no natural time ordering dominates)
--   - All Phase 4 indexes are recreated on each partition (PostgreSQL inherits them
--     automatically when a partitioned index is defined on the parent).
--
-- How to run (on the LARGE dataset database, after sql/01_schema.sql):
--   psql -d <large_db> -f sql/08_partitioning.sql
--   psql -d <large_db> -f sql/02_load_data.sql   (with large_data/ folder)
--   psql -d <large_db> -f sql/05_indexes.sql      (indexes inherit to partitions)
-- =====================================================================

SET search_path TO housing;

-- =====================================================================
-- PART 1: Partition `properties` by RANGE on posted_at
-- =====================================================================

-- Step 1: Rename the existing table (preserve it; we re-insert via INSERT SELECT)
ALTER TABLE properties RENAME TO properties_old;

-- Step 2: Create the partitioned parent (identical columns, no data)
CREATE TABLE properties (
    property_id          INTEGER       NOT NULL,
    listed_by            INTEGER       NOT NULL,
    project_id           INTEGER,
    locality_id          INTEGER       NOT NULL,
    listing_type         VARCHAR(4)    NOT NULL,
    property_type        VARCHAR(20)   NOT NULL,
    bhk                  SMALLINT,
    carpet_area_sqft     INTEGER       NOT NULL,
    floor_no             SMALLINT,
    total_floors         SMALLINT,
    furnishing           VARCHAR(20),
    facing               VARCHAR(12)   NOT NULL,
    price                NUMERIC(12,2) NOT NULL,
    maintenance_monthly  NUMERIC(10,2),
    security_deposit     NUMERIC(12,2),
    available_from       DATE          NOT NULL,
    latitude             NUMERIC(9,6)  NOT NULL,
    longitude            NUMERIC(9,6)  NOT NULL,
    is_verified          BOOLEAN       NOT NULL DEFAULT FALSE,
    status               VARCHAR(10)   NOT NULL,
    posted_at            TIMESTAMPTZ   NOT NULL,

    -- constraints (same as Phase 2)
    CONSTRAINT pk_properties PRIMARY KEY (property_id, posted_at),   -- PK must include partition key
    CONSTRAINT ck_prop_listing_type  CHECK (listing_type IN ('RENT', 'SALE')),
    CONSTRAINT ck_prop_property_type
        CHECK (property_type IN ('APARTMENT', 'INDEPENDENT_HOUSE', 'VILLA', 'PLOT')),
    CONSTRAINT ck_prop_furnishing
        CHECK (furnishing IS NULL OR furnishing IN ('UNFURNISHED', 'SEMI_FURNISHED', 'FULLY_FURNISHED')),
    CONSTRAINT ck_prop_facing
        CHECK (facing IN ('NORTH', 'SOUTH', 'EAST', 'WEST',
                          'NORTH_EAST', 'NORTH_WEST', 'SOUTH_EAST', 'SOUTH_WEST')),
    CONSTRAINT ck_prop_status   CHECK (status IN ('ACTIVE', 'INACTIVE', 'RENTED', 'SOLD')),
    CONSTRAINT ck_prop_bhk      CHECK (bhk BETWEEN 1 AND 10),
    CONSTRAINT ck_prop_area     CHECK (carpet_area_sqft > 0),
    CONSTRAINT ck_prop_price    CHECK (price > 0),
    CONSTRAINT ck_prop_lat      CHECK (latitude  BETWEEN 6 AND 38),
    CONSTRAINT ck_prop_lng      CHECK (longitude BETWEEN 68 AND 98),
    CONSTRAINT ck_prop_plot_vs_bhk          CHECK ((property_type = 'PLOT') = (bhk IS NULL)),
    CONSTRAINT ck_prop_plot_vs_furnishing   CHECK ((property_type = 'PLOT') = (furnishing IS NULL)),
    CONSTRAINT ck_prop_plot_vs_total_floors CHECK ((property_type = 'PLOT') = (total_floors IS NULL)),
    CONSTRAINT ck_prop_floor_only_apartment CHECK ((property_type = 'APARTMENT') = (floor_no IS NOT NULL)),
    CONSTRAINT ck_prop_project_type         CHECK (project_id IS NULL OR property_type IN ('APARTMENT', 'VILLA')),
    CONSTRAINT ck_prop_deposit_only_rent    CHECK (listing_type = 'RENT' OR security_deposit IS NULL),
    CONSTRAINT ck_prop_status_vs_listing    CHECK ((status <> 'RENTED' OR listing_type = 'RENT')
                                               AND (status <> 'SOLD'   OR listing_type = 'SALE'))
) PARTITION BY RANGE (posted_at);

-- Step 3: Partitions — one per year + a catch-all default
CREATE TABLE properties_2023
    PARTITION OF properties
    FOR VALUES FROM ('2023-01-01') TO ('2024-01-01');

CREATE TABLE properties_2024
    PARTITION OF properties
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');

CREATE TABLE properties_2025
    PARTITION OF properties
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');

CREATE TABLE properties_2026
    PARTITION OF properties
    FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');

CREATE TABLE properties_future
    PARTITION OF properties DEFAULT;

-- Step 4: Foreign keys that REFERENCE properties must point at the parent
--         (FK columns on child tables reference property_id; we keep them as-is
--          because PostgreSQL 16 supports FK → partitioned table when the PK
--          includes the partition key — here we reference only property_id).
-- Re-add the outgoing FKs from properties:
ALTER TABLE properties ADD CONSTRAINT fk_properties_lister
    FOREIGN KEY (listed_by)   REFERENCES users (user_id)          ON DELETE RESTRICT;
ALTER TABLE properties ADD CONSTRAINT fk_properties_project
    FOREIGN KEY (project_id)  REFERENCES projects (project_id)    ON DELETE SET NULL;
ALTER TABLE properties ADD CONSTRAINT fk_properties_locality
    FOREIGN KEY (locality_id) REFERENCES localities (locality_id) ON DELETE RESTRICT;

-- Step 5: Migrate existing data from the renamed old table
INSERT INTO properties SELECT * FROM properties_old;

-- Step 6: Drop the old unpartitioned table
DROP TABLE properties_old;

-- =====================================================================
-- PART 2: Partition `enquiries` by HASH (8 buckets)
-- Enquiries are accessed by property_id or user_id, not by date.
-- Hash partitioning distributes the 2M rows evenly across 8 partitions.
-- =====================================================================

ALTER TABLE enquiries RENAME TO enquiries_old;

CREATE TABLE enquiries (
    enquiry_id   INTEGER      NOT NULL,
    property_id  INTEGER      NOT NULL,
    user_id      INTEGER      NOT NULL,
    channel      VARCHAR(10)  NOT NULL,
    message      VARCHAR(500),
    created_at   TIMESTAMPTZ  NOT NULL,

    CONSTRAINT pk_enquiries PRIMARY KEY (enquiry_id, property_id),
    CONSTRAINT fk_enq_property FOREIGN KEY (property_id) REFERENCES properties (property_id)   ON DELETE CASCADE,
    CONSTRAINT fk_enq_user     FOREIGN KEY (user_id)     REFERENCES users (user_id)             ON DELETE CASCADE,
    CONSTRAINT ck_enq_channel  CHECK (channel IN ('CALL', 'WHATSAPP', 'FORM'))
) PARTITION BY HASH (property_id);

CREATE TABLE enquiries_h0 PARTITION OF enquiries FOR VALUES WITH (MODULUS 8, REMAINDER 0);
CREATE TABLE enquiries_h1 PARTITION OF enquiries FOR VALUES WITH (MODULUS 8, REMAINDER 1);
CREATE TABLE enquiries_h2 PARTITION OF enquiries FOR VALUES WITH (MODULUS 8, REMAINDER 2);
CREATE TABLE enquiries_h3 PARTITION OF enquiries FOR VALUES WITH (MODULUS 8, REMAINDER 3);
CREATE TABLE enquiries_h4 PARTITION OF enquiries FOR VALUES WITH (MODULUS 8, REMAINDER 4);
CREATE TABLE enquiries_h5 PARTITION OF enquiries FOR VALUES WITH (MODULUS 8, REMAINDER 5);
CREATE TABLE enquiries_h6 PARTITION OF enquiries FOR VALUES WITH (MODULUS 8, REMAINDER 6);
CREATE TABLE enquiries_h7 PARTITION OF enquiries FOR VALUES WITH (MODULUS 8, REMAINDER 7);

INSERT INTO enquiries SELECT * FROM enquiries_old;
DROP TABLE enquiries_old;

-- =====================================================================
-- PART 3: Partition `price_changes` by RANGE on changed_at (quarterly)
-- At 20× there will be ~470k rows; quarterly slabs keep each partition
-- small enough for index-only scans in R08.
-- =====================================================================

ALTER TABLE price_changes RENAME TO price_changes_old;

CREATE TABLE price_changes (
    change_id    INTEGER        NOT NULL,
    property_id  INTEGER        NOT NULL,
    old_price    NUMERIC(12,2)  NOT NULL,
    new_price    NUMERIC(12,2)  NOT NULL,
    changed_at   TIMESTAMPTZ    NOT NULL,

    CONSTRAINT pk_price_changes PRIMARY KEY (change_id, changed_at),
    CONSTRAINT fk_pc_property FOREIGN KEY (property_id) REFERENCES properties (property_id) ON DELETE CASCADE,
    CONSTRAINT ck_pc_old_price CHECK (old_price > 0),
    CONSTRAINT ck_pc_new_price CHECK (new_price > 0),
    CONSTRAINT ck_pc_differs   CHECK (new_price <> old_price)
) PARTITION BY RANGE (changed_at);

CREATE TABLE price_changes_2024q1 PARTITION OF price_changes FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');
CREATE TABLE price_changes_2024q2 PARTITION OF price_changes FOR VALUES FROM ('2024-04-01') TO ('2024-07-01');
CREATE TABLE price_changes_2024q3 PARTITION OF price_changes FOR VALUES FROM ('2024-07-01') TO ('2024-10-01');
CREATE TABLE price_changes_2024q4 PARTITION OF price_changes FOR VALUES FROM ('2024-10-01') TO ('2025-01-01');
CREATE TABLE price_changes_2025q1 PARTITION OF price_changes FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');
CREATE TABLE price_changes_2025q2 PARTITION OF price_changes FOR VALUES FROM ('2025-04-01') TO ('2025-07-01');
CREATE TABLE price_changes_2025q3 PARTITION OF price_changes FOR VALUES FROM ('2025-07-01') TO ('2025-10-01');
CREATE TABLE price_changes_2025q4 PARTITION OF price_changes FOR VALUES FROM ('2025-10-01') TO ('2026-01-01');
CREATE TABLE price_changes_2026q1 PARTITION OF price_changes FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');
CREATE TABLE price_changes_2026q2 PARTITION OF price_changes FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');
CREATE TABLE price_changes_2026q3 PARTITION OF price_changes FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');
CREATE TABLE price_changes_future  PARTITION OF price_changes DEFAULT;

INSERT INTO price_changes SELECT * FROM price_changes_old;
DROP TABLE price_changes_old;

-- =====================================================================
-- PART 4: Refresh planner statistics across all partitions
-- =====================================================================
ANALYZE;

-- =====================================================================
-- Summary of partitions created
-- =====================================================================
SELECT
    parent.relname                             AS parent_table,
    child.relname                              AS partition_name,
    pg_get_expr(child.relpartbound, child.oid) AS bounds
FROM pg_inherits
JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
JOIN pg_class child  ON child.oid  = pg_inherits.inhrelid
JOIN pg_namespace ns ON ns.oid = parent.relnamespace
WHERE ns.nspname = 'housing'
ORDER BY parent.relname, child.relname;
