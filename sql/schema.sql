-- schema.sql — PostGIS schema for MAPC Zoning Atlas ETL
--
-- Run once against your AWS RDS PostGIS instance before the first ETL run:
--   psql -h <RDS_HOST> -U <USER> -d <DBNAME> -f sql/schema.sql
--
-- CRS: All geometry stored in EPSG:26986 (NAD83 / Massachusetts Mainland, metres).
--      Use ST_Transform(geometry, 4326) in queries that serve web maps.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE SCHEMA IF NOT EXISTS mapc;

-- Column names mirror MAPC Zoning Atlas field names (lowercased).
-- Nullable columns reflect that not all municipalities populate all fields.
CREATE TABLE IF NOT EXISTS mapc.zoning_atlas (
    id              SERIAL PRIMARY KEY,

    -- MAPC identifiers
    muni_id         TEXT,
    muni            TEXT,             -- e.g. "Cambridge"
    zo_code         TEXT,
    zo_abbr         TEXT,             -- e.g. "R1", "B2"
    zo_name         TEXT,
    zo_usety        TEXT,             -- residential / commercial / industrial / etc.

    -- Multifamily housing allowance by building size (0=not allowed, 1=by-right, 2=special permit)
    mulfam2         SMALLINT,         -- 2-unit
    mulfam3_4       SMALLINT,         -- 3-4 unit
    mulfam5_19      SMALLINT,         -- 5-19 unit
    mulfam20_       SMALLINT,         -- 20+ unit

    -- Derived by transform step
    area_m2         NUMERIC(18, 2),   -- EPSG:26986
    area_acres      NUMERIC(12, 4),
    centroid_x      NUMERIC(12, 2),   -- easting, EPSG:26986
    centroid_y      NUMERIC(12, 2),   -- northing, EPSG:26986

    -- ETL provenance
    etl_run_id      TEXT NOT NULL,    -- links to etl_runs.run_id
    etl_loaded_at   TIMESTAMPTZ,

    -- EPSG:26986 — use ST_Transform(geometry, 4326) for web map output
    geometry        GEOMETRY(MultiPolygon, 26986)
);

COMMENT ON TABLE  mapc.zoning_atlas                IS 'MAPC Greater Boston Zoning Atlas — zoning district polygons for 101 municipalities. Source: https://www.mapc.org/planning101/zoning-atlas/';
COMMENT ON COLUMN mapc.zoning_atlas.geometry       IS 'Zoning district boundary. CRS: EPSG:26986 (NAD83 / Massachusetts Mainland). Use ST_Transform(geometry, 4326) for web map output.';
COMMENT ON COLUMN mapc.zoning_atlas.area_m2        IS 'District area in square metres, calculated in EPSG:26986 (accurate for Massachusetts).';
COMMENT ON COLUMN mapc.zoning_atlas.etl_run_id     IS 'UUID linking this row to the etl_runs audit table.';

-- Spatial index
CREATE INDEX IF NOT EXISTS idx_zoning_atlas_geom
    ON mapc.zoning_atlas USING GIST (geometry);

-- Attribute indexes for common filter queries
CREATE INDEX IF NOT EXISTS idx_zoning_atlas_muni_id  ON mapc.zoning_atlas (muni_id);
CREATE INDEX IF NOT EXISTS idx_zoning_atlas_zo_usety ON mapc.zoning_atlas (zo_usety);
CREATE INDEX IF NOT EXISTS idx_zoning_atlas_etl_run  ON mapc.zoning_atlas (etl_run_id);

CREATE TABLE IF NOT EXISTS mapc.etl_runs (
    run_id       TEXT PRIMARY KEY,
    table_name   TEXT NOT NULL,
    row_count    INTEGER,
    started_at   TIMESTAMPTZ DEFAULT now(),
    completed_at TIMESTAMPTZ
);

COMMENT ON TABLE mapc.etl_runs IS 'Audit log of each ETL pipeline run — one row per execution.';

CREATE TABLE IF NOT EXISTS mapc.qaqc_log (
    id          SERIAL PRIMARY KEY,
    run_id      TEXT NOT NULL REFERENCES mapc.etl_runs(run_id) ON DELETE CASCADE,
    check_name  TEXT NOT NULL,
    passed      BOOLEAN NOT NULL,
    value       TEXT,             -- observed metric value (cast to text for flexibility)
    threshold   TEXT,             -- acceptable limit this check is evaluated against
    critical    BOOLEAN NOT NULL, -- if true, failure should halt the pipeline
    note        TEXT,
    checked_at  TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE  mapc.qaqc_log            IS 'QA/QC check results per ETL run. Join to etl_runs on run_id.';
COMMENT ON COLUMN mapc.qaqc_log.critical   IS 'If true, a failed check means the pipeline should not proceed.';
COMMENT ON COLUMN mapc.qaqc_log.value      IS 'The observed metric value (e.g. null rate, feature count).';
COMMENT ON COLUMN mapc.qaqc_log.threshold  IS 'The acceptable limit this check is evaluated against.';

CREATE INDEX IF NOT EXISTS idx_qaqc_log_run_id ON mapc.qaqc_log (run_id);
