"""Bronze: land extract files as delivered, append-only, with lineage columns.

Nothing is cleaned here. Every column stays a string so a bad value in SAP
never breaks ingestion; typing happens in silver. A file is ingested once:
files already in the bronze table (by file name) are skipped, which makes a
re-run safe. On Databricks this step could be swapped for Auto Loader with
no change to silver or gold.
"""
from __future__ import annotations

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

from .config import Settings

# bronze table -> folder under the landing path
SOURCES = {
    "ish_npat": "sap_ish/NPAT",
    "ish_nfal": "sap_ish/NFAL",
    "ish_nbew": "sap_ish/NBEW",
    "ish_nlei": "sap_ish/NLEI",
    "ish_ntpk": "sap_ish/NTPK",
    "claim_837_line": "claims_837",
}


def ingest_source(spark: SparkSession, settings: Settings, table: str, folder: str) -> int:
    """Append new files from one landing folder to its bronze table. Returns rows added."""
    target = settings.table("bronze", table)
    raw = (
        spark.read.option("header", True)
        .option("inferSchema", False)            # everything as string
        .option("ignoreLeadingWhiteSpace", False)
        .option("ignoreTrailingWhiteSpace", False)
        .csv(f"{settings.landing_path}/{folder}")
        .withColumn("_source_file", F.element_at(F.split(F.col("_metadata.file_path"), "/"), -1))
        .withColumn("_ingested_at", F.current_timestamp())
    )

    if spark.catalog.tableExists(target):
        seen = spark.table(target).select("_source_file").distinct()
        raw = raw.join(seen, "_source_file", "left_anti")

    new_rows = raw.cache()
    count = new_rows.count()
    if count:
        new_rows.write.format(settings.table_format).mode("append").saveAsTable(target)
    new_rows.unpersist()
    return count


def run(spark: SparkSession, settings: Settings) -> dict[str, int]:
    spark.sql(f"CREATE SCHEMA IF NOT EXISTS {settings.schema('bronze')}")
    return {table: ingest_source(spark, settings, table, folder) for table, folder in SOURCES.items()}
