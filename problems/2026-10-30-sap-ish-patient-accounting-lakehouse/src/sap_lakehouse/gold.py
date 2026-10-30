"""Gold: encounter and charge facts, and SAP charge vs 837 claim reconciliation.

gold.fact_encounter        one row per SAP case
gold.fact_charge           one row per SAP service posting, priced from the service master
gold.recon_charge_vs_claim one row per (case, CPT, service date) -- SAP side vs 837 side
gold.revenue_integrity_summary  by department and recon status, with dollars at risk

Why reconcile at (case, CPT, date) and not per SAP posting: in SAP a quantity
correction is usually a cancellation (STORN = 'X') plus a new posting with a
new LNRLS. Line-by-line matching would report that as "cancelled but billed"
plus "not billed". Aggregating active quantity per key reports what really
happened: the units changed after the claim went out.
"""
from __future__ import annotations

from pyspark.sql import DataFrame, SparkSession
from pyspark.sql import functions as F

from .config import Settings

AMOUNT_TOLERANCE = 0.005   # half a cent


def fact_encounter(spark: SparkSession, settings: Settings) -> DataFrame:
    case = spark.table(settings.table("silver", "ish_case"))
    pat = spark.table(settings.table("silver", "ish_patient"))
    mov = spark.table(settings.table("silver", "ish_movement")).filter(~F.col("is_cancelled"))

    mov_agg = mov.groupBy("case_id").agg(
        F.min(F.when(F.col("movement_type").isin("ADMISSION", "OUTPATIENT_VISIT"),
                     F.col("movement_ts"))).alias("admit_ts"),
        F.max(F.when(F.col("movement_type") == "DISCHARGE", F.col("movement_ts"))).alias("discharge_ts"),
        F.min_by("department", "movement_ts").alias("admitting_department"),
        F.max_by("department", "movement_ts").alias("discharging_department"),
        F.count("*").alias("movement_count"),
    )
    cutoff = F.to_date(F.lit(settings.claims_cutoff_date))
    return (
        case.join(mov_agg, "case_id", "left")
        .join(pat.select("patient_id", "birth_date", "sex_code"), "patient_id", "left")
        .select(
            "case_id", "case_id_ext", "institution", "patient_id", "case_type",
            "case_start_date", "case_end_date", "admit_ts", "discharge_ts",
            "admitting_department", "discharging_department", "movement_count",
            F.when(F.col("case_type") == "INPATIENT",
                   F.datediff("case_end_date", "case_start_date")).alias("length_of_stay_days"),
            F.floor(F.months_between("case_start_date", "birth_date") / 12).cast("int")
             .alias("age_at_admission"),
            "sex_code",
            F.col("case_end_date").isNull().alias("is_open"),
            "is_cancelled",
            # The billing run covered every case closed by the cutoff, cancelled or not.
            (F.col("case_end_date") <= cutoff).alias("in_billing_scope"),
        )
    )


def fact_charge(spark: SparkSession, settings: Settings, encounter: DataFrame) -> DataFrame:
    svc = spark.table(settings.table("silver", "ish_service"))
    cat = spark.table(settings.table("silver", "ish_service_catalog"))
    enc = encounter.select(
        "case_id", "case_id_ext", "patient_id",
        F.col("admitting_department").alias("department"),
        F.col("is_cancelled").alias("case_cancelled"), "in_billing_scope",
    )
    return (
        svc.join(cat, ["tariff", "service_code"], "left")
        .join(enc, "case_id", "left")
        .select(
            "service_doc_id", "case_id", "case_id_ext", "patient_id", "department",
            "service_code", "cpt_code", "description", "service_date", "quantity", "unit_price",
            (F.col("quantity") * F.col("unit_price")).cast("decimal(15,2)").alias("charge_amount"),
            (F.col("is_cancelled") | F.coalesce(F.col("case_cancelled"), F.lit(False)))
             .alias("is_cancelled"),
            F.coalesce(F.col("in_billing_scope"), F.lit(False)).alias("in_billing_scope"),
        )
    )


def recon_charge_vs_claim(spark: SparkSession, settings: Settings, charge: DataFrame) -> DataFrame:
    key = ["case_id", "cpt_code", "service_date"]
    active = ~F.col("is_cancelled")

    sap = (
        charge.filter("in_billing_scope")
        .groupBy(*key)
        .agg(
            F.sum(F.when(active, F.col("quantity")).otherwise(0)).alias("sap_quantity"),
            F.sum(F.when(active, F.col("charge_amount")).otherwise(0)).alias("sap_amount"),
            F.sum(F.when(active, 1).otherwise(0)).alias("sap_active_postings"),
            F.sum(F.when(~active, 1).otherwise(0)).alias("sap_cancelled_postings"),
            F.sort_array(F.collect_list("service_doc_id")).alias("sap_service_doc_ids"),
        )
    )
    clm = (
        spark.table(settings.table("silver", "claim_837_line"))
        .groupBy(*key)
        .agg(
            F.first("claim_id").alias("claim_id"),
            F.sum("units").alias("claim_units"),
            F.sum("billed_amount").alias("claim_amount"),
            F.count("*").alias("claim_lines"),
        )
    )

    j = sap.join(clm, key, "full_outer")
    has_active = F.coalesce(F.col("sap_active_postings"), F.lit(0)) > 0
    has_sap = F.col("sap_service_doc_ids").isNotNull()
    has_claim = F.col("claim_lines").isNotNull()

    status = (
        F.when(has_active & ~has_claim, "NOT_BILLED")                    # revenue leakage
        .when(~has_sap & has_claim, "BILLED_NOT_IN_SAP")                 # compliance risk
        .when(has_sap & ~has_active & has_claim, "CANCELLED_BUT_BILLED") # compliance risk
        .when(has_sap & ~has_active & ~has_claim, "CANCELLED_NOT_BILLED")  # correct, kept for audit
        .when(F.col("sap_quantity") != F.col("claim_units"), "UNITS_MISMATCH")
        .when(F.abs(F.col("sap_amount") - F.col("claim_amount")) > AMOUNT_TOLERANCE, "AMOUNT_MISMATCH")
        .otherwise("MATCHED")
    )
    return j.select(
        *key, "claim_id",
        F.coalesce("sap_quantity", F.lit(0)).alias("sap_quantity"),
        F.coalesce("claim_units", F.lit(0)).alias("claim_units"),
        F.coalesce("sap_amount", F.lit(0)).cast("decimal(15,2)").alias("sap_amount"),
        F.coalesce("claim_amount", F.lit(0)).cast("decimal(15,2)").alias("claim_amount"),
        (F.coalesce("claim_amount", F.lit(0)) - F.coalesce("sap_amount", F.lit(0)))
         .cast("decimal(15,2)").alias("amount_variance"),
        "sap_active_postings", "sap_cancelled_postings", "sap_service_doc_ids", "claim_lines",
        status.alias("recon_status"),
    )


def revenue_integrity_summary(recon: DataFrame, encounter: DataFrame) -> DataFrame:
    dept = encounter.select("case_id", F.col("admitting_department").alias("department"))
    return (
        recon.join(dept, "case_id", "left")
        .withColumn("department", F.coalesce("department", F.lit("UNKNOWN")))
        .groupBy("department", "recon_status")
        .agg(
            F.count("*").alias("keys"),
            F.sum("sap_amount").alias("sap_amount"),
            F.sum("claim_amount").alias("claim_amount"),
            F.sum("amount_variance").alias("amount_variance"),
        )
    )


def run(spark: SparkSession, settings: Settings) -> dict[str, int]:
    spark.sql(f"CREATE SCHEMA IF NOT EXISTS {settings.schema('gold')}")

    def save(df: DataFrame, name: str) -> DataFrame:
        (df.write.format(settings.table_format).mode("overwrite")
           .option("overwriteSchema", "true").saveAsTable(settings.table("gold", name)))
        return spark.table(settings.table("gold", name))

    enc = save(fact_encounter(spark, settings), "fact_encounter")
    chg = save(fact_charge(spark, settings, enc), "fact_charge")
    rec = save(recon_charge_vs_claim(spark, settings, chg), "recon_charge_vs_claim")
    summ = save(revenue_integrity_summary(rec, enc), "revenue_integrity_summary")
    return {"fact_encounter": enc.count(), "fact_charge": chg.count(),
            "recon_charge_vs_claim": rec.count(), "revenue_integrity_summary": summ.count()}
