"""Command-line entry point. Also the entry point of the Databricks wheel task.

    python -m sap_lakehouse.pipeline --layer all --conf local
    python -m sap_lakehouse.pipeline --layer silver --conf databricks
"""
from __future__ import annotations

import argparse

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

from . import bronze, gold, silver
from .config import Settings, get_spark, load_settings

LAYERS = {"bronze": bronze.run, "silver": silver.run, "gold": gold.run}


def run(spark: SparkSession, settings: Settings, layers: list[str]) -> dict[str, dict[str, int]]:
    results = {}
    for layer in layers:
        results[layer] = LAYERS[layer](spark, settings)
        print(f"[{layer}] " + ", ".join(f"{t}={n:,}" for t, n in results[layer].items()))
    return results


def print_recon_report(spark: SparkSession, settings: Settings) -> None:
    rec = spark.table(settings.table("gold", "recon_charge_vs_claim"))
    print("\nReconciliation: SAP IS-H charges vs 837 claim lines (keys = case, CPT, date)")
    (rec.groupBy("recon_status")
        .agg(F.count("*").alias("keys"),
             F.sum("sap_amount").alias("sap_amount"),
             F.sum("claim_amount").alias("claim_amount"),
             F.sum("amount_variance").alias("variance"))
        .orderBy(F.col("recon_status") == "MATCHED", "recon_status")
        .show(truncate=False))


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--layer", choices=["all", *LAYERS], default="all")
    ap.add_argument("--conf", default="local", help="settings file in sap_lakehouse/conf/")
    args = ap.parse_args(argv)

    settings = load_settings(args.conf)
    spark = get_spark(settings)
    if settings.catalog is None:          # sparkContext is not exposed on serverless / shared compute
        spark.sparkContext.setLogLevel("ERROR")
    layers = list(LAYERS) if args.layer == "all" else [args.layer]
    run(spark, settings, layers)
    if "gold" in layers:
        print_recon_report(spark, settings)


if __name__ == "__main__":
    main()
