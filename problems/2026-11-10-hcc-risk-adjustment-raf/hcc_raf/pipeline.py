"""Wires the three steps together. Pure DataFrame-in / DataFrame-out, so the
same functions run in a notebook, a scheduled job, or a unit test."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from pyspark.sql import DataFrame, SparkSession
from pyspark.sql import functions as F

from .config import (
    CLAIM_DX_SCHEMA, CLAIM_HEADER_SCHEMA, MEMBER_SCHEMA,
    ModelConfig, ReferenceTables, load_config, load_reference_tables,
)
from .filters import build_dx_audit
from .hierarchy import apply_hierarchies, member_hccs
from .scoring import score_members


@dataclass
class RafResult:
    dx_audit: DataFrame
    member_hcc: DataFrame
    member_raf: DataFrame


def get_spark(app_name: str = "hcc-raf") -> SparkSession:
    spark = (
        SparkSession.builder.master("local[*]")
        .appName(app_name)
        .config("spark.sql.shuffle.partitions", "4")
        .config("spark.ui.enabled", "false")
        .config("spark.sql.session.timeZone", "UTC")
        .getOrCreate()
    )
    spark.sparkContext.setLogLevel("ERROR")
    return spark


def read_inputs(spark: SparkSession, data_dir: str | Path) -> tuple[DataFrame, DataFrame, DataFrame]:
    d = Path(data_dir)
    opts = {"header": True, "mode": "FAILFAST", "dateFormat": "yyyy-MM-dd"}
    members = spark.read.csv(str(d / "members.csv"), schema=MEMBER_SCHEMA, **opts)
    headers = spark.read.csv(str(d / "claim_headers.csv"), schema=CLAIM_HEADER_SCHEMA, **opts)
    dx = spark.read.csv(str(d / "claim_diagnoses.csv"), schema=CLAIM_DX_SCHEMA, **opts)
    return members, headers, dx


def compute_raf(
    members: DataFrame,
    headers: DataFrame,
    dx_lines: DataFrame,
    ref: ReferenceTables,
    cfg: ModelConfig,
) -> RafResult:
    dx_audit = build_dx_audit(dx_lines, headers, members, ref.dx_to_hcc, cfg).cache()
    member_hcc = member_hccs(dx_audit).transform(lambda df: apply_hierarchies(df, ref.hierarchy)).cache()
    member_raf = score_members(members, member_hcc, ref, cfg).cache()
    return RafResult(dx_audit, member_hcc, member_raf)


def run(spark: SparkSession, data_dir: str | Path, model_dir: str | Path) -> RafResult:
    cfg = load_config(model_dir)
    ref = load_reference_tables(spark, model_dir, cfg)
    return compute_raf(*read_inputs(spark, data_dir), ref, cfg)


def write_outputs(result: RafResult, out_dir: str | Path) -> None:
    """CSV for easy eyeballing; arrays are flattened to pipe-delimited strings."""
    out = Path(out_dir)

    def _flat(df: DataFrame) -> DataFrame:
        for name, dtype in df.dtypes:
            if dtype.startswith("array"):
                df = df.withColumn(name, F.concat_ws("|", F.col(name).cast("array<string>")))
        return df

    for name, df in [("dx_audit", result.dx_audit), ("member_hcc", result.member_hcc), ("member_raf", result.member_raf)]:
        _flat(df).coalesce(1).write.mode("overwrite").csv(str(out / name), header=True)
