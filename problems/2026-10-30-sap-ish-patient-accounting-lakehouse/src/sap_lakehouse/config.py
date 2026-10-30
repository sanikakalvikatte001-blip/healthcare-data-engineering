"""Environment settings. One JSON file per environment in sap_lakehouse/conf/.

The same code runs locally (Parquet tables in a local Spark warehouse) and on
Databricks (Delta tables in a Unity Catalog catalog). Only this file and the
JSON settings know the difference.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from importlib import resources

from pyspark.sql import SparkSession


@dataclass(frozen=True)
class Settings:
    env: str
    catalog: str | None          # Unity Catalog catalog; None = local spark_catalog
    table_format: str            # "delta" on Databricks, "parquet" locally
    landing_path: str            # root folder that holds sap_ish/ and claims_837/
    sap_client: str              # production MANDT to keep
    claims_cutoff_date: str      # cases discharged on/before this date were billed
    local_warehouse_dir: str | None = None

    def table(self, layer: str, name: str) -> str:
        """Fully qualified table name, e.g. hc_dev.silver.ish_case or silver.ish_case."""
        return f"{self.catalog}.{layer}.{name}" if self.catalog else f"{layer}.{name}"

    def schema(self, layer: str) -> str:
        return f"{self.catalog}.{layer}" if self.catalog else layer


def load_settings(env: str = "local", **overrides) -> Settings:
    raw = json.loads(resources.files("sap_lakehouse.conf").joinpath(f"{env}.json").read_text())
    raw.update(overrides)
    return Settings(env=env, **raw)


def get_spark(settings: Settings) -> SparkSession:
    """Return the active session on Databricks; build a small one locally."""
    if settings.catalog:  # running on Databricks: a session already exists
        return SparkSession.builder.getOrCreate()
    # Local Hive metastore (Derby) so tables survive between runs, like a real
    # catalog. Metastore and data both live under local_warehouse_dir.
    warehouse = os.path.abspath(settings.local_warehouse_dir)
    return (
        SparkSession.builder.master("local[*]")
        .appName("sap-ish-lakehouse")
        .config("spark.sql.warehouse.dir", warehouse)
        .config("spark.driver.extraJavaOptions", f"-Dderby.system.home={warehouse}")
        .config("spark.sql.shuffle.partitions", "4")
        .config("spark.ui.enabled", "false")
        .config("spark.sql.session.timeZone", "UTC")
        .enableHiveSupport()
        .getOrCreate()
    )
