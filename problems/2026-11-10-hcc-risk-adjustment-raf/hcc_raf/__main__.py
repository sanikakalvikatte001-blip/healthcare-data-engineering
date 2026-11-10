"""Command line entry point.

    python -m hcc_raf run      --data data --model model --out output
    python -m hcc_raf explain  --data data --model model --member M9001
"""
from __future__ import annotations

import argparse

from pyspark.sql import functions as F

from .pipeline import get_spark, run, write_outputs


def _summary(result) -> None:
    print("\n== Diagnosis line status ==")
    (result.dx_audit.groupBy("dx_status").count()
        .orderBy(F.desc("count")).show(truncate=False))

    print("== HCC hierarchy outcome ==")
    result.member_hcc.groupBy("hcc_status").count().orderBy("hcc_status").show()

    print("== Member RAF distribution ==")
    raf = result.member_raf
    raf.select(
        F.count("*").alias("members"),
        F.sum(F.when(F.col("payment_hcc_count") == 0, 1).otherwise(0)).alias("members_no_hcc"),
        F.round(F.avg("raw_raf"), 3).alias("avg_raw_raf"),
        F.round(F.avg("payment_raf"), 3).alias("avg_payment_raf"),
        F.round(F.expr("percentile_approx(payment_raf, 0.5)"), 3).alias("median_payment_raf"),
        F.max("payment_raf").alias("max_payment_raf"),
    ).show()

    print("== Top 10 payment HCCs by member count ==")
    (result.member_hcc.where("hcc_status = 'PAYMENT'")
        .groupBy("hcc").agg(F.countDistinct("member_id").alias("members"))
        .orderBy(F.desc("members"), "hcc").limit(10).show())

    print("== Interactions triggered ==")
    (raf.select(F.explode("interactions").alias("interaction"))
        .groupBy("interaction").count().orderBy("interaction").show())


def _explain(result, member_id: str) -> None:
    print(f"\n== Member {member_id}: RAF ==")
    result.member_raf.where(F.col("member_id") == member_id).show(vertical=True, truncate=False)
    print("== HCCs ==")
    (result.member_hcc.where(F.col("member_id") == member_id)
        .select("hcc", "hcc_status", "trumped_by", "supporting_icd10", "supporting_claims")
        .orderBy("hcc").show(truncate=False))
    print("== Diagnosis lines ==")
    (result.dx_audit.where(F.col("member_id") == member_id)
        .select("claim_id", "claim_version", "through_dos", "icd10_raw", "hcc", "dx_status")
        .orderBy("through_dos", "claim_id", "claim_version").show(50, truncate=False))


def main(argv=None) -> None:
    p = argparse.ArgumentParser(prog="hcc_raf", description="CMS-HCC style RAF scoring (PySpark)")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("run", "explain"):
        s = sub.add_parser(name)
        s.add_argument("--data", default="data")
        s.add_argument("--model", default="model")
        if name == "run":
            s.add_argument("--out", default="output")
        else:
            s.add_argument("--member", required=True)
    args = p.parse_args(argv)

    spark = get_spark()
    try:
        result = run(spark, args.data, args.model)
        if args.cmd == "run":
            write_outputs(result, args.out)
            _summary(result)
            print(f"Outputs written to {args.out}/")
        else:
            _explain(result, args.member)
    finally:
        spark.stop()


if __name__ == "__main__":
    main()
