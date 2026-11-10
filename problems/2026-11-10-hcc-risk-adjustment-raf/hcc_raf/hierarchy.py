"""Step 2 -- roll accepted diagnoses up to member HCCs and apply hierarchies.

Within a disease family only the most severe HCC pays (e.g. CKD stage 5
trumps CKD stage 4). A trumped HCC is kept in the output with the HCC(s)
that trumped it, because coders and auditors ask about those all the time.
"""
from __future__ import annotations

from pyspark.sql import DataFrame
from pyspark.sql import functions as F


def member_hccs(dx_audit: DataFrame) -> DataFrame:
    """Distinct member x HCC, with the evidence that supports it."""
    return (
        dx_audit
        .where(F.col("dx_status") == "ACCEPTED")
        .groupBy("member_id", "hcc")
        .agg(
            F.countDistinct("claim_id").alias("supporting_claims"),
            F.min("through_dos").alias("first_dos"),
            F.max("through_dos").alias("last_dos"),
            F.array_sort(F.collect_set("icd10")).alias("supporting_icd10"),
        )
    )


def apply_hierarchies(hccs: DataFrame, hierarchy: DataFrame) -> DataFrame:
    """Add ``hcc_status`` (PAYMENT | TRUMPED) and ``trumped_by`` (array of parent HCCs).

    Set-based: a child HCC is trumped when the same member also has any of its
    parents. Because the hierarchy table is transitively closed (validated at
    load time), one join is enough -- no recursion needed.
    """
    child = hccs.select("member_id", F.col("hcc").alias("child_hcc"))
    parent = hccs.select("member_id", F.col("hcc").alias("parent_hcc"))

    trumped = (
        child
        .join(hierarchy, "child_hcc")
        .join(parent, ["member_id", "parent_hcc"])
        .groupBy("member_id", F.col("child_hcc").alias("hcc"))
        .agg(F.array_sort(F.collect_set("parent_hcc")).alias("trumped_by"))
    )

    return (
        hccs
        .join(trumped, ["member_id", "hcc"], "left")
        .withColumn("hcc_status", F.when(F.col("trumped_by").isNull(), "PAYMENT").otherwise("TRUMPED"))
    )
