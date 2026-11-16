-- =====================================================================
-- sql/01_schema.sql
-- Housing.com Property Search Database (DBMS project)
-- Phase 2: schema reverse-engineered from seed_data/*.csv
-- Target: PostgreSQL 15+. Runs top-to-bottom on an empty database.
--
-- Rules followed:
--   * everything lives in schema "housing"
--   * ONLY constraints (PK, FK, UNIQUE, NOT NULL, CHECK) - no tuning indexes
--   * the only indexes that exist are the ones PostgreSQL builds
--     automatically for PRIMARY KEY and UNIQUE constraints (listed at the end)
--
-- Note: queries that compare timestamps with date literals (R04, R07, R08,
-- R12, R20 ...) depend on the session time zone. The data is Indian, so run
-- benchmarks with:  ALTER DATABASE <dbname> SET timezone TO 'Asia/Kolkata';
-- =====================================================================

DROP SCHEMA IF EXISTS housing CASCADE;
CREATE SCHEMA housing;
SET search_path TO housing;

-- ---------------------------------------------------------------------
-- 1. cities  (10 rows)
-- ---------------------------------------------------------------------
CREATE TABLE cities (
    city_id    INTEGER      PRIMARY KEY,
    city_name  VARCHAR(50)  NOT NULL,
    state      VARCHAR(50)  NOT NULL,
    CONSTRAINT uq_cities_name UNIQUE (city_name),
    CONSTRAINT ck_cities_name_not_blank  CHECK (btrim(city_name) <> ''),
    CONSTRAINT ck_cities_state_not_blank CHECK (btrim(state) <> '')
);

-- ---------------------------------------------------------------------
-- 2. localities  (100 rows)   city 1 --- N locality
-- ---------------------------------------------------------------------
CREATE TABLE localities (
    locality_id    INTEGER       PRIMARY KEY,
    city_id        INTEGER       NOT NULL,
    locality_name  VARCHAR(100)  NOT NULL,
    pincode        CHAR(6)       NOT NULL,
    center_lat     NUMERIC(9,6)  NOT NULL,
    center_lng     NUMERIC(9,6)  NOT NULL,
    CONSTRAINT fk_localities_city
        FOREIGN KEY (city_id) REFERENCES cities (city_id) ON DELETE RESTRICT,
    CONSTRAINT uq_localities_city_name UNIQUE (city_id, locality_name),
    CONSTRAINT ck_localities_pincode CHECK (pincode ~ '^[1-9][0-9]{5}$'),
    CONSTRAINT ck_localities_lat CHECK (center_lat BETWEEN 6 AND 38),
    CONSTRAINT ck_localities_lng CHECK (center_lng BETWEEN 68 AND 98)
);

-- ---------------------------------------------------------------------
-- 3. builders  (150 rows)
-- ---------------------------------------------------------------------
CREATE TABLE builders (
    builder_id    INTEGER       PRIMARY KEY,
    builder_name  VARCHAR(100)  NOT NULL,
    founded_year  SMALLINT      NOT NULL,
    CONSTRAINT uq_builders_name UNIQUE (builder_name),
    CONSTRAINT ck_builders_founded CHECK (founded_year BETWEEN 1850 AND 2026)
);

-- ---------------------------------------------------------------------
-- 4. projects  (1,200 rows)   builder 1 --- N project, locality 1 --- N project
-- rera_id is optional but unique: a UNIQUE column accepts many NULLs in
-- PostgreSQL (NULL <> NULL), so the 171 projects without RERA id are fine.
-- ---------------------------------------------------------------------
CREATE TABLE projects (
    project_id         INTEGER       PRIMARY KEY,
    builder_id         INTEGER       NOT NULL,
    locality_id        INTEGER       NOT NULL,
    project_name       VARCHAR(150)  NOT NULL,
    rera_id            VARCHAR(20),
    possession_status  VARCHAR(20)   NOT NULL,
    possession_date    DATE          NOT NULL,
    total_units        INTEGER       NOT NULL,
    CONSTRAINT fk_projects_builder
        FOREIGN KEY (builder_id)  REFERENCES builders (builder_id)   ON DELETE RESTRICT,
    CONSTRAINT fk_projects_locality
        FOREIGN KEY (locality_id) REFERENCES localities (locality_id) ON DELETE RESTRICT,
    CONSTRAINT uq_projects_rera UNIQUE (rera_id),
    CONSTRAINT ck_projects_rera_format
        CHECK (rera_id IS NULL OR rera_id ~ '^[A-Z]{2}-RERA-PR-[0-9]{8}$'),
    CONSTRAINT ck_projects_status
        CHECK (possession_status IN ('READY_TO_MOVE', 'UNDER_CONSTRUCTION')),
    CONSTRAINT ck_projects_units CHECK (total_units > 0),
    CONSTRAINT ck_projects_name_not_blank CHECK (btrim(project_name) <> '')
);

-- ---------------------------------------------------------------------
-- 5. amenities  (15 rows)
-- ---------------------------------------------------------------------
CREATE TABLE amenities (
    amenity_id    INTEGER      PRIMARY KEY,
    amenity_name  VARCHAR(50)  NOT NULL,
    CONSTRAINT uq_amenities_name UNIQUE (amenity_name)
);

-- ---------------------------------------------------------------------
-- 6. project_amenities  (6,806 rows)   project M --- N amenity
-- Composite PK: a project either offers an amenity or it does not.
-- ---------------------------------------------------------------------
CREATE TABLE project_amenities (
    project_id  INTEGER NOT NULL,
    amenity_id  INTEGER NOT NULL,
    CONSTRAINT pk_project_amenities PRIMARY KEY (project_id, amenity_id),
    CONSTRAINT fk_pa_project
        FOREIGN KEY (project_id) REFERENCES projects (project_id)  ON DELETE CASCADE,
    CONSTRAINT fk_pa_amenity
        FOREIGN KEY (amenity_id) REFERENCES amenities (amenity_id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- 7. users  (40,000 rows)   one table for SEEKER / OWNER / AGENT
-- email is optional (15,990 NULLs) but unique when present.
-- agent_rera_id exists for AGENT rows only.
-- ---------------------------------------------------------------------
CREATE TABLE users (
    user_id        INTEGER       PRIMARY KEY,
    full_name      VARCHAR(100)  NOT NULL,
    phone          CHAR(10)      NOT NULL,
    email          VARCHAR(150),
    user_type      VARCHAR(10)   NOT NULL,
    agent_rera_id  VARCHAR(20),
    created_at     TIMESTAMPTZ   NOT NULL,
    CONSTRAINT uq_users_phone UNIQUE (phone),
    CONSTRAINT uq_users_email UNIQUE (email),
    CONSTRAINT uq_users_agent_rera UNIQUE (agent_rera_id),
    CONSTRAINT ck_users_name_not_blank CHECK (btrim(full_name) <> ''),
    CONSTRAINT ck_users_phone CHECK (phone ~ '^[6-9][0-9]{9}$'),
    CONSTRAINT ck_users_email CHECK (email IS NULL OR email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    CONSTRAINT ck_users_type CHECK (user_type IN ('SEEKER', 'OWNER', 'AGENT')),
    CONSTRAINT ck_users_agent_rera_format
        CHECK (agent_rera_id IS NULL OR agent_rera_id ~ '^AG-RERA-[0-9]{8}$'),
    -- only agents carry an agent RERA id, and every agent must have one
    CONSTRAINT ck_users_agent_rera_only_agents
        CHECK ((user_type = 'AGENT') = (agent_rera_id IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- 8. properties  (120,060 rows)
--   user 1 --- N property (listed_by), locality 1 --- N property,
--   project 1 --- N property (optional)
-- ---------------------------------------------------------------------
CREATE TABLE properties (
    property_id          INTEGER       PRIMARY KEY,
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
    maintenance_monthly  NUMERIC(10,2),   -- in the seed: empty exactly when project_id is empty
    security_deposit     NUMERIC(12,2),   -- in the seed: empty for every SALE row
    available_from       DATE          NOT NULL,
    latitude             NUMERIC(9,6)  NOT NULL,
    longitude            NUMERIC(9,6)  NOT NULL,
    is_verified          BOOLEAN       NOT NULL DEFAULT FALSE,
    status               VARCHAR(10)   NOT NULL,
    posted_at            TIMESTAMPTZ   NOT NULL,

    CONSTRAINT fk_properties_lister
        FOREIGN KEY (listed_by)   REFERENCES users (user_id)          ON DELETE RESTRICT,
    CONSTRAINT fk_properties_project
        FOREIGN KEY (project_id)  REFERENCES projects (project_id)    ON DELETE SET NULL,
    CONSTRAINT fk_properties_locality
        FOREIGN KEY (locality_id) REFERENCES localities (locality_id) ON DELETE RESTRICT,

    -- allowed values
    CONSTRAINT ck_prop_listing_type  CHECK (listing_type IN ('RENT', 'SALE')),
    CONSTRAINT ck_prop_property_type
        CHECK (property_type IN ('APARTMENT', 'INDEPENDENT_HOUSE', 'VILLA', 'PLOT')),
    CONSTRAINT ck_prop_furnishing
        CHECK (furnishing IS NULL OR furnishing IN ('UNFURNISHED', 'SEMI_FURNISHED', 'FULLY_FURNISHED')),
    CONSTRAINT ck_prop_facing
        CHECK (facing IN ('NORTH', 'SOUTH', 'EAST', 'WEST',
                          'NORTH_EAST', 'NORTH_WEST', 'SOUTH_EAST', 'SOUTH_WEST')),
    CONSTRAINT ck_prop_status
        CHECK (status IN ('ACTIVE', 'INACTIVE', 'RENTED', 'SOLD')),

    -- ranges
    CONSTRAINT ck_prop_bhk          CHECK (bhk BETWEEN 1 AND 10),
    CONSTRAINT ck_prop_area         CHECK (carpet_area_sqft > 0),
    CONSTRAINT ck_prop_floor_no     CHECK (floor_no >= 0),
    CONSTRAINT ck_prop_total_floors CHECK (total_floors >= 1),
    CONSTRAINT ck_prop_price        CHECK (price > 0),
    CONSTRAINT ck_prop_maintenance  CHECK (maintenance_monthly IS NULL OR maintenance_monthly >= 0),
    CONSTRAINT ck_prop_deposit      CHECK (security_deposit IS NULL OR security_deposit >= 0),
    CONSTRAINT ck_prop_lat          CHECK (latitude  BETWEEN 6 AND 38),
    CONSTRAINT ck_prop_lng          CHECK (longitude BETWEEN 68 AND 98),

    -- rules that tie columns together
    -- a plot has no BHK, no furnishing, no floors; every built property has all three
    CONSTRAINT ck_prop_plot_vs_bhk
        CHECK ((property_type = 'PLOT') = (bhk IS NULL)),
    CONSTRAINT ck_prop_plot_vs_furnishing
        CHECK ((property_type = 'PLOT') = (furnishing IS NULL)),
    CONSTRAINT ck_prop_plot_vs_total_floors
        CHECK ((property_type = 'PLOT') = (total_floors IS NULL)),
    -- only a flat sits on a particular floor, and it cannot be above the top floor
    CONSTRAINT ck_prop_floor_only_apartment
        CHECK ((property_type = 'APARTMENT') = (floor_no IS NOT NULL)),
    CONSTRAINT ck_prop_floor_le_total
        CHECK (floor_no IS NULL OR floor_no <= total_floors),
    -- only apartments and villas can belong to a project; houses and plots are stand-alone
    CONSTRAINT ck_prop_project_type
        CHECK (project_id IS NULL OR property_type IN ('APARTMENT', 'VILLA')),
    -- security deposit exists only for rentals
    CONSTRAINT ck_prop_deposit_only_rent
        CHECK (listing_type = 'RENT' OR security_deposit IS NULL),
    -- RENTED only for rentals, SOLD only for sales
    CONSTRAINT ck_prop_status_vs_listing
        CHECK ((status <> 'RENTED' OR listing_type = 'RENT')
           AND (status <> 'SOLD'   OR listing_type = 'SALE'))
);

-- ---------------------------------------------------------------------
-- 9. price_changes  (23,425 rows)   property 1 --- N price change (history)
-- ---------------------------------------------------------------------
CREATE TABLE price_changes (
    change_id    INTEGER        PRIMARY KEY,
    property_id  INTEGER        NOT NULL,
    old_price    NUMERIC(12,2)  NOT NULL,
    new_price    NUMERIC(12,2)  NOT NULL,
    changed_at   TIMESTAMPTZ    NOT NULL,
    CONSTRAINT fk_pc_property
        FOREIGN KEY (property_id) REFERENCES properties (property_id) ON DELETE CASCADE,
    CONSTRAINT ck_pc_old_price CHECK (old_price > 0),
    CONSTRAINT ck_pc_new_price CHECK (new_price > 0),
    CONSTRAINT ck_pc_differs   CHECK (new_price <> old_price)
);

-- ---------------------------------------------------------------------
-- 10. enquiries  (100,000 rows)   seeker N --- N property (with payload)
-- A seeker may enquire again later, so (property_id, user_id) is NOT unique
-- by design, even though the seed data happens to have no repeats.
-- ---------------------------------------------------------------------
CREATE TABLE enquiries (
    enquiry_id   INTEGER      PRIMARY KEY,
    property_id  INTEGER      NOT NULL,
    user_id      INTEGER      NOT NULL,
    channel      VARCHAR(10)  NOT NULL,
    message      VARCHAR(500),
    created_at   TIMESTAMPTZ  NOT NULL,
    CONSTRAINT fk_enq_property
        FOREIGN KEY (property_id) REFERENCES properties (property_id) ON DELETE CASCADE,
    CONSTRAINT fk_enq_user
        FOREIGN KEY (user_id)     REFERENCES users (user_id)          ON DELETE CASCADE,
    CONSTRAINT ck_enq_channel CHECK (channel IN ('CALL', 'WHATSAPP', 'FORM'))
);

-- ---------------------------------------------------------------------
-- 11. site_visits  (35,120 rows)
-- feedback_rating is empty unless the visit was COMPLETED (and even then the
-- seeker may skip it: 6,427 completed visits have no rating).
-- W03 inserts a visit with only status = 'SCHEDULED', so rating must be nullable.
-- ---------------------------------------------------------------------
CREATE TABLE site_visits (
    visit_id         INTEGER      PRIMARY KEY,
    property_id      INTEGER      NOT NULL,
    user_id          INTEGER      NOT NULL,
    scheduled_at     TIMESTAMPTZ  NOT NULL,
    status           VARCHAR(10)  NOT NULL,
    feedback_rating  SMALLINT,
    CONSTRAINT fk_sv_property
        FOREIGN KEY (property_id) REFERENCES properties (property_id) ON DELETE CASCADE,
    CONSTRAINT fk_sv_user
        FOREIGN KEY (user_id)     REFERENCES users (user_id)          ON DELETE CASCADE,
    CONSTRAINT ck_sv_status
        CHECK (status IN ('SCHEDULED', 'COMPLETED', 'CANCELLED', 'NO_SHOW')),
    CONSTRAINT ck_sv_rating CHECK (feedback_rating BETWEEN 1 AND 5),
    CONSTRAINT ck_sv_rating_only_completed
        CHECK (feedback_rating IS NULL OR status = 'COMPLETED')
);

-- ---------------------------------------------------------------------
-- 12. shortlists  (69,999 rows)   seeker M --- N property
-- Composite PK: a seeker shortlists a given property at most once.
-- ---------------------------------------------------------------------
CREATE TABLE shortlists (
    user_id      INTEGER      NOT NULL,
    property_id  INTEGER      NOT NULL,
    added_at     TIMESTAMPTZ  NOT NULL,
    CONSTRAINT pk_shortlists PRIMARY KEY (user_id, property_id),
    CONSTRAINT fk_sl_user
        FOREIGN KEY (user_id)     REFERENCES users (user_id)          ON DELETE CASCADE,
    CONSTRAINT fk_sl_property
        FOREIGN KEY (property_id) REFERENCES properties (property_id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- Indexes that exist after this script (all created automatically by
-- PostgreSQL for PRIMARY KEY / UNIQUE constraints; none created by hand):
--   cities           : pk(city_id), uq(city_name)
--   localities       : pk(locality_id), uq(city_id, locality_name)
--   builders         : pk(builder_id), uq(builder_name)
--   projects         : pk(project_id), uq(rera_id)
--   amenities        : pk(amenity_id), uq(amenity_name)
--   project_amenities: pk(project_id, amenity_id)
--   users            : pk(user_id), uq(phone), uq(email), uq(agent_rera_id)
--   properties       : pk(property_id)
--   price_changes    : pk(change_id)
--   enquiries        : pk(enquiry_id)
--   site_visits      : pk(visit_id)
--   shortlists       : pk(user_id, property_id)
-- Foreign-key columns are NOT indexed automatically in PostgreSQL; that is
-- left for Phase 4 (sql/05_indexes.sql).
-- ---------------------------------------------------------------------