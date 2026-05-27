# Database Schema Documentation

**Database:** AWS RDS PostgreSQL + PostGIS  
**Schema:** `mapc`  
**CRS (storage):** EPSG:26986 — NAD83 / Massachusetts Mainland (metres)  
**CRS (web output):** EPSG:4326 — use `ST_Transform(geometry, 4326)` in queries

---

## Tables

### `mapc.zoning_atlas`

Primary data table. One row per zoning district polygon in the MAPC Zoning Atlas (101 Greater Boston municipalities).

| Column | Type | Nullable | Description |
| :--- | :--- | :--- | :--- |
| **id** | SERIAL | NO | Surrogate primary key (auto-generated) |
| **muni_id** | DOUBLE PRECISION | YES | Municipality numeric identifier |
| **muni** | TEXT | YES | Municipality name/abbreviation (e.g., Cambridge) |
| **zo_code** | TEXT | YES | System-generated zoning code |
| **zo_name** | TEXT | YES | Full name of the local zoning district |
| **zo_usety** | BIGINT | YES | Standardized MAPC use type code (categorical integer) |
| **zo_abbr** | TEXT | YES | Local zoning abbreviation (e.g., R1, B2) |
| **zo_usede** | TEXT | YES | Standardized use description |
| **mf_notes** | TEXT | YES | Qualitative notes regarding multifamily allowances |
| **mulfam2** | BIGINT | YES | Duplex allowance code (1=By-Right, 2=Special Permit, 0=Prohibited) |
| **mulfam3_4** | BIGINT | YES | 3 to 4 unit housing density allowance code |
| **mulfam5_19** | BIGINT | YES | 5 to 19 unit housing density allowance code |
| **mulfam20_** | BIGINT | YES | 20+ unit housing density allowance code |
| **minlotsize** | DOUBLE PRECISION | YES | Minimum required lot size per municipal bylaws |
| **pctlotcov** | DOUBLE PRECISION | YES | Maximum allowed percentage of lot coverage |
| **maxflrs** | DOUBLE PRECISION | YES | Maximum allowed height in structural floors |
| **maxheight** | DOUBLE PRECISION | YES | Maximum allowed building height |
| **maxdu** | DOUBLE PRECISION | YES | Maximum dwelling units baseline |
| **far** | DOUBLE PRECISION | YES | Floor Area Ratio (total floor area relative to plot size) |
| **geometry** | GEOMETRY(MultiPolygon, 26986) | YES | Spatial boundary reprojected to Mass Mainland State Plane |
| **area_m2** | DOUBLE PRECISION | YES | District area calculated in square meters |
| **area_acres**| DOUBLE PRECISION | YES | District area calculated in acres |
| **centroid_x** | DOUBLE PRECISION | YES | Calculated polygon centroid easting coordinate |
| **centroid_y** | DOUBLE PRECISION | YES | Calculated polygon centroid northing coordinate |
| **etl_run_id** | TEXT | NO | Execution UUID tracing back to `mapc.etl_runs` |
| **etl_loaded_at**| TEXT | YES | Timestamp tracking exactly when data hit the table |

**Indexes:**
- `idx_zoning_atlas_geom` — GIST on `geometry` (spatial queries)
- `idx_zoning_atlas_muni_id` — B-tree on `muni_id`
- `idx_zoning_atlas_zo_usety` — B-tree on `zo_usety`
- `idx_zoning_atlas_etl_run` — B-tree on `etl_run_id`

---

### `mapc.etl_runs`

Audit table — one row per pipeline execution.

| Column | Type | Description |
|--------|------|-------------|
| `run_id` | TEXT PK | UUID generated at pipeline start |
| `table_name` | TEXT | Fully-qualified target table (`mapc.zoning_atlas`) |
| `row_count` | INTEGER | Number of rows loaded in this run |
| `started_at` | TIMESTAMPTZ | When the run started (default: `now()`) |
| `completed_at` | TIMESTAMPTZ | When load finished |

---

### `mapc.qaqc_log`

QA/QC check results — one row per check per run.

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL PK | Auto-increment |
| `run_id` | TEXT FK → `etl_runs.run_id` | Pipeline run this check belongs to |
| `check_name` | TEXT | Check identifier (e.g. `feature_count`, `null_rate_muni_name`) |
| `passed` | BOOLEAN | Whether the check passed |
| `value` | TEXT | Observed value (cast to text) |
| `threshold` | TEXT | Acceptable limit evaluated against |
| `critical` | BOOLEAN | If `true`, failure aborts the pipeline |
| `note` | TEXT | Human-readable explanation |
| `checked_at` | TIMESTAMPTZ | When this check ran |

---

## Useful Queries

```sql
-- Most recent ETL run summary
SELECT run_id, row_count, completed_at
FROM mapc.etl_runs
ORDER BY completed_at DESC
LIMIT 1;

-- All failed QA checks for the absolute latest single run
SELECT q.check_name, q.value, q.threshold, q.note
FROM mapc.qaqc_log q
WHERE NOT q.passed
  AND q.run_id = (
      SELECT run_id 
      FROM mapc.etl_runs 
      ORDER BY completed_at DESC 
      LIMIT 1
  )
ORDER BY q.check_name;

-- Zoning districts by use type
SELECT zo_usety, COUNT(*), ROUND(SUM(area_acres)::numeric, 0) AS total_acres
FROM mapc.zoning_atlas
GROUP BY zo_usety
ORDER BY total_acres DESC;

-- Multifamily-allowed zones within Cambridge
SELECT zo_code, zo_abbr, zo_name, area_acres
FROM mapc.zoning_atlas
WHERE muni = 'Cambridge'
  AND (mulfam2 > 0 OR mulfam3_4 > 0 OR mulfam5_19 > 0 OR mulfam20_ > 0)
ORDER BY area_acres DESC;

-- Export to GeoJSON (WGS84) for web map use
SELECT json_build_object(
    'type', 'FeatureCollection',
    'features', json_agg(ST_AsGeoJSON(t.*)::json)
)
FROM (
    SELECT zo_code, muni, zo_abbr, zo_usety, area_acres,
           ST_Transform(geometry, 4326) AS geometry
    FROM mapc.zoning_atlas
    WHERE muni = 'Somerville'
) t;
```
