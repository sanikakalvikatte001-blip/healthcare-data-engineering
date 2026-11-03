"""
FHIR R4 Bulk Data export (NDJSON) -> flat, warehouse-ready tables with PySpark.

The Python here is a thin driver. All transformation logic lives in Spark SQL files
under ./sql and runs in file-name order:

    01_patient.sql        latest version per Patient, flatten names/identifiers/telecom
    02_encounter.sql      latest version per Encounter, resolve Patient reference
    03_observation.sql    resolve references, pick LOINC, explode BP components, value[x]
    04_quarantine.sql     every rejected line/resource with a reason code
    05_load_summary.sql   line-level reconciliation: input = malformed + superseded + quarantined + loaded
    06_latest_measures.sql  PIVOT: latest vitals/labs per patient (a typical downstream mart)

Usage:
    python flatten_fhir.py --input data/export --output output
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

from pyspark.sql import DataFrame, SparkSession
from pyspark.sql import functions as F

from fhir_schemas import RESOURCES

HERE = Path(__file__).resolve().parent
SQL_DIR = HERE / "sql"

# Views written out as tables at the end of the run.
OUTPUT_VIEWS = ["patient_flat", "encounter_flat", "observation_flat",
                "quarantine", "load_summary", "patient_latest_measures"]


def build_spark(app_name: str = "fhir-bulk-flatten") -> SparkSession:
    """Local Spark session. UTC so FHIR instants with offsets compare correctly."""
    return (SparkSession.builder
            .master("local[*]")
            .appName(app_name)
            .config("spark.sql.session.timeZone", "UTC")
            .config("spark.sql.shuffle.partitions", "4")
            .config("spark.ui.enabled", "false")
            .config("spark.ui.showConsoleProgress", "false")
            .getOrCreate())


def register_raw_views(spark: SparkSession, input_dir: str | Path) -> None:
    """Read every <ResourceType>.*.ndjson file with its explicit schema into a raw_* view."""
    input_dir = Path(input_dir)
    for resource_type, (schema, view) in RESOURCES.items():
        files = sorted(str(p) for p in input_dir.glob(f"{resource_type}.*.ndjson"))
        if not files:
            raise FileNotFoundError(f"No {resource_type}.*.ndjson files in {input_dir}")
        df: DataFrame = (spark.read
                         .schema(schema)
                         .option("mode", "PERMISSIVE")                      # bad lines -> _corrupt_record
                         .option("columnNameOfCorruptRecord", "_corrupt_record")
                         .json(files)
                         .withColumn("source_file", F.regexp_extract(F.input_file_name(), r"([^/]+)$", 1)))
        # Spark refuses queries that touch only _corrupt_record on an un-cached JSON scan.
        df.cache().createOrReplaceTempView(view)


def split_statements(sql_text: str) -> list[str]:
    """Split a .sql file on statement-ending semicolons (';' at end of a line)."""
    parts = re.split(r";\s*$", sql_text, flags=re.MULTILINE)
    stmts = []
    for part in parts:
        # skip chunks that are only comments / whitespace
        code = "\n".join(l for l in part.splitlines() if not l.strip().startswith("--")).strip()
        if code:
            stmts.append(part.strip())
    return stmts


def run_sql_layer(spark: SparkSession, sql_dir: Path = SQL_DIR) -> None:
    for sql_file in sorted(sql_dir.glob("*.sql")):
        for stmt in split_statements(sql_file.read_text()):
            spark.sql(stmt)


def run_pipeline(spark: SparkSession, input_dir: str | Path) -> dict[str, DataFrame]:
    """Run the whole flatten and return the output views as DataFrames."""
    register_raw_views(spark, input_dir)
    run_sql_layer(spark)
    return {v: spark.table(v) for v in OUTPUT_VIEWS}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", default=str(HERE / "data" / "export"))
    ap.add_argument("--output", default=str(HERE / "output"))
    args = ap.parse_args()

    spark = build_spark()
    spark.sparkContext.setLogLevel("ERROR")
    tables = run_pipeline(spark, args.input)

    for name, df in tables.items():
        df.write.mode("overwrite").parquet(str(Path(args.output) / name))

    print("\n== Load summary (line-level reconciliation) ==")
    tables["load_summary"].show(truncate=False)
    print("== Quarantine by reason ==")
    tables["quarantine"].groupBy("resource_type", "reason").count().orderBy("resource_type", "reason").show(truncate=False)
    print("== Observation rows by value type ==")
    tables["observation_flat"].groupBy("value_type").count().orderBy("value_type").show()
    print("== Sample: latest measures per patient ==")
    tables["patient_latest_measures"].orderBy("patient_id").show(5, truncate=False)
    print(f"Parquet tables written to {args.output}")
    spark.stop()


if __name__ == "__main__":
    main()
