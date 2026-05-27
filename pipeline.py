"""
pipeline.py — MAPC Zoning Atlas spatial ETL — main orchestrator.

Usage:
    python pipeline.py              # Full run
    DRY_RUN=true python pipeline.py # Validate without writing to DB
    FORCE_DOWNLOAD=true python pipeline.py  # Re-download source data

Exit codes:
    0 — Pipeline completed successfully, all QA/QC checks passed
    1 — Pipeline completed but QA/QC critical check(s) failed
    2 — Pipeline aborted due to an unhandled error
"""

import logging
import sys
import uuid
from datetime import datetime, timezone

import config
from etl.extract import download_mapc_zoning
from etl.transform import transform
from etl.load import load_zoning, get_engine, ensure_schema
from etl.qaqc import run_all_checks

config.LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(config.LOG_DIR / "etl.log", encoding="utf-8"),
    ],
)
logger = logging.getLogger("pipeline")


def main() -> int:
    run_id = str(uuid.uuid4())
    started_at = datetime.now(timezone.utc).isoformat()

    logger.info("MAPC Zoning Atlas ETL | run_id=%s | started=%s%s",
                run_id, started_at, "  [DRY RUN]" if config.DRY_RUN else "")

    try:
        logger.info("Step 1/4 — Extract")
        gdf_raw = download_mapc_zoning(force=config.FORCE_DOWNLOAD)

        logger.info("Step 2/4 — Transform")
        gdf = transform(gdf_raw, run_id=run_id)

        if not config.DRY_RUN:
            ensure_schema(get_engine())

        logger.info("Step 3/4 — Pre-load QA/QC")
        if not run_all_checks(gdf, run_id=run_id, skip_db_checks=True):
            logger.error("Pre-load QA/QC failed — aborting load")
            return 1

        logger.info("Step 4/4 — Load to PostGIS")
        row_count = load_zoning(gdf, run_id=run_id, mode="replace")

        if not config.DRY_RUN:
            logger.info("Post-load QA/QC")
            if not run_all_checks(gdf, run_id=run_id, expected_count=row_count, skip_db_checks=False):
                logger.error("Post-load QA/QC failed — data is loaded but review qaqc_log")
                return 1

    except Exception as exc:
        logger.exception("Pipeline aborted with unhandled error: %s", exc)
        return 2

    logger.info("Pipeline complete | run_id=%s | %d features loaded", run_id, row_count)
    return 0


if __name__ == "__main__":
    sys.exit(main())