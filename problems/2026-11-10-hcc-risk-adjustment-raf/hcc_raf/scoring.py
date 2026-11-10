"""Step 3 -- turn demographics + payment HCCs into a risk adjustment factor (RAF).

    raw_raf     = demographic factor
                + sum(payment HCC coefficients)
                + sum(triggered interaction coefficients)
                + payment-HCC count coefficient
    normalized  = raw_raf / normalization_factor
    payment_raf = normalized * (1 - coding_intensity_adjustment)

Every member in the enrollment file gets a row, including members with no
claims at all (they still carry a demographic score).
"""
from __future__ import annotations

from pyspark.sql import DataFrame
from pyspark.sql import functions as F

from .config import ModelConfig, ReferenceTables


def age_as_of(birth_col: str, as_of) -> F.Column:
    """Whole years of age on ``as_of`` -- birthday-exact, leap-day safe.

    CMS uses age as of February 1 of the payment year.
    """
    asof = F.lit(as_of)
    before_birthday = (F.month(birth_col) > F.month(asof)) | (
        (F.month(birth_col) == F.month(asof)) & (F.dayofmonth(birth_col) > F.dayofmonth(asof))
    )
    return F.year(asof) - F.year(birth_col) - F.when(before_birthday, 1).otherwise(0)


def add_demographics(cfg: ModelConfig, demo: DataFrame):
    def _transform(members: DataFrame) -> DataFrame:
        with_age = members.withColumn("age", age_as_of("birth_date", cfg.age_as_of))
        return with_age.join(
            demo,
            (with_age.sex == demo.sex) & with_age.age.between(demo.age_lo, demo.age_hi),
            "left",
        ).select(with_age["*"], F.col("factor").alias("demographic_factor"))
    return _transform


def disease_scores(payment_hccs: DataFrame, coefficients: DataFrame) -> DataFrame:
    return (
        payment_hccs.join(coefficients, "hcc")
        .groupBy("member_id")
        .agg(
            F.sum("coefficient").alias("disease_score"),
            F.count("*").alias("payment_hcc_count"),
            F.array_sort(F.collect_list("hcc")).alias("payment_hccs"),
        )
    )


def interaction_scores(payment_hccs: DataFrame, interactions: DataFrame) -> DataFrame:
    """An interaction fires when the member hits every one of its HCC groups."""
    hits = (
        payment_hccs.join(interactions, "hcc")
        .groupBy("member_id", "interaction", "n_groups", "coefficient")
        .agg(F.countDistinct("group_idx").alias("groups_hit"))
        .where(F.col("groups_hit") == F.col("n_groups"))
    )
    return hits.groupBy("member_id").agg(
        F.sum("coefficient").alias("interaction_score"),
        F.array_sort(F.collect_list("interaction")).alias("interactions"),
    )


def score_members(
    members: DataFrame,
    hcc_table: DataFrame,
    ref: ReferenceTables,
    cfg: ModelConfig,
) -> DataFrame:
    payment = hcc_table.where(F.col("hcc_status") == "PAYMENT").select("member_id", "hcc")

    scored = (
        members
        .transform(add_demographics(cfg, ref.demographic_factors))
        .join(disease_scores(payment, ref.hcc_coefficients), "member_id", "left")
        .join(interaction_scores(payment, ref.interactions), "member_id", "left")
        .fillna({"disease_score": 0.0, "interaction_score": 0.0, "payment_hcc_count": 0})
    )

    cv = ref.count_variables
    scored = (
        scored.join(F.broadcast(cv), scored.payment_hcc_count.between(cv.min_hccs, cv.max_hccs), "left")
        .drop("min_hccs", "max_hccs")
        .fillna({"count_coefficient": 0.0})
        .withColumnRenamed("count_coefficient", "count_score")
    )

    raw = F.col("demographic_factor") + F.col("disease_score") + F.col("interaction_score") + F.col("count_score")
    return (
        scored
        .withColumn("disease_score", F.round("disease_score", 3))
        .withColumn("interaction_score", F.round("interaction_score", 3))
        .withColumn("raw_raf", F.round(raw, 3))
        .withColumn("normalized_raf", F.round(raw / F.lit(cfg.normalization_factor), 3))
        .withColumn(
            "payment_raf",
            F.round(raw / F.lit(cfg.normalization_factor) * F.lit(1 - cfg.coding_intensity_adjustment), 3),
        )
        .withColumn("payment_hccs", F.coalesce("payment_hccs", F.array().cast("array<int>")))
        .withColumn("interactions", F.coalesce("interactions", F.array().cast("array<string>")))
        .select(
            "member_id", "sex", "birth_date", "age", "demographic_factor",
            "payment_hcc_count", "payment_hccs", "disease_score",
            "interactions", "interaction_score", "count_variable", "count_score",
            "raw_raf", "normalized_raf", "payment_raf",
        )
    )
