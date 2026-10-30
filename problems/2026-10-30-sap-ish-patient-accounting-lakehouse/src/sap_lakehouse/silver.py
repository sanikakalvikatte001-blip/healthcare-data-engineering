"""Silver: current-state, typed, readable tables.

For each SAP table:
  1. keep only the production client (MANDT)
  2. apply the ODP change log -> current image per key
  3. convert SAP types (DATS, TIMS, QUAN, NUMC/ALPHA, 'X' flags)
  4. rename SAP field names to business names (SAP name kept in comments)
"""
from __future__ import annotations

from pyspark.sql import DataFrame, SparkSession
from pyspark.sql import functions as F

from .cdc import apply_changes
from .config import Settings
from .sap_types import alpha_in, alpha_out, sap_date, sap_flag, sap_number, sap_timestamp

MOVEMENT_TYPES = {"1": "ADMISSION", "2": "DISCHARGE", "3": "TRANSFER", "4": "OUTPATIENT_VISIT"}


def _current(spark: SparkSession, settings: Settings, table: str, keys: list[str]) -> DataFrame:
    changes = spark.table(settings.table("bronze", table)).filter(
        F.trim("MANDT") == settings.sap_client
    )
    return apply_changes(changes, ["MANDT", *keys])


def patient(spark, settings) -> DataFrame:
    p = _current(spark, settings, "ish_npat", ["PATNR"])
    return p.select(
        F.trim("PATNR").alias("patient_id"),                       # NPAT-PATNR
        sap_date("GBDAT").alias("birth_date"),                     # NPAT-GBDAT
        F.when(F.trim("GSCHL") == "1", "M")
         .when(F.trim("GSCHL") == "2", "F").otherwise("U").alias("sex_code"),  # NPAT-GSCHL
        F.trim("PSTLZ").alias("postal_code"),
        "_last_change_tsn",
    )


def case(spark, settings) -> DataFrame:
    c = _current(spark, settings, "ish_nfal", ["EINRI", "FALNR"])
    return c.select(
        F.trim("EINRI").alias("institution"),                      # NFAL-EINRI
        alpha_in("FALNR").alias("case_id"),                        # NFAL-FALNR (internal)
        alpha_out("FALNR").alias("case_id_ext"),                   # as printed / sent in CLM01
        F.trim("PATNR").alias("patient_id"),
        F.when(F.trim("FALAR") == "1", "INPATIENT").otherwise("OUTPATIENT").alias("case_type"),
        sap_date("BEGDT").alias("case_start_date"),
        sap_date("ENDDT").alias("case_end_date"),
        sap_flag("STORN").alias("is_cancelled"),                   # NFAL-STORN
        "_last_change_tsn",
    )


def movement(spark, settings) -> DataFrame:
    m = _current(spark, settings, "ish_nbew", ["EINRI", "FALNR", "LFDNR"])
    mtype = F.trim("BEWTY")
    movement_type = F.lit(None).cast("string")
    for code, name in MOVEMENT_TYPES.items():
        movement_type = F.when(mtype == code, name).otherwise(movement_type)
    return m.select(
        alpha_in("FALNR").alias("case_id"),
        F.trim("LFDNR").cast("int").alias("movement_seq"),         # NBEW-LFDNR
        movement_type.alias("movement_type"),                      # NBEW-BEWTY
        sap_timestamp("BWIDT", "BWIZT").alias("movement_ts"),      # NBEW-BWIDT + BWIZT
        F.trim("ORGFA").alias("department"),                       # NBEW-ORGFA
        sap_flag("STORN").alias("is_cancelled"),
        "_last_change_tsn",
    )


def service(spark, settings) -> DataFrame:
    s = _current(spark, settings, "ish_nlei", ["EINRI", "LNRLS"])
    return s.select(
        F.trim("LNRLS").alias("service_doc_id"),                   # NLEI-LNRLS
        alpha_in("FALNR").alias("case_id"),
        F.trim("TARIF").alias("tariff"),
        F.trim("LEIST").alias("service_code"),                     # NLEI-LEIST
        sap_date("IBGDT").alias("service_date"),                   # NLEI-IBGDT
        sap_number("IMENG", 13, 3).alias("quantity"),              # NLEI-IMENG
        sap_flag("STORN").alias("is_cancelled"),
        "_last_change_tsn",
    )


def service_catalog(spark, settings) -> DataFrame:
    t = _current(spark, settings, "ish_ntpk", ["EINRI", "TARIF", "LEIST"])
    return t.select(
        F.trim("TARIF").alias("tariff"),
        F.trim("LEIST").alias("service_code"),
        F.trim("KTXT").alias("description"),
        F.trim("ZZCPT").alias("cpt_code"),                         # customer field: CPT crosswalk
        sap_number("PREIS", 13, 2).alias("unit_price"),
    )


def claim_line(spark, settings) -> DataFrame:
    """837P lines from the billing system (already parsed from X12 upstream)."""
    c = spark.table(settings.table("bronze", "claim_837_line"))
    return (
        c.select(
            F.trim("file_id").alias("file_id"),
            F.trim("claim_id").alias("claim_id"),                  # CLM01 patient control no.
            alpha_in("claim_id").alias("case_id"),                 # CLM01 -> SAP FALNR
            F.trim("line_no").cast("int").alias("line_no"),
            F.upper(F.trim("cpt_code")).alias("cpt_code"),
            sap_date("service_from_date").alias("service_date"),
            F.trim("units").cast("decimal(13,3)").alias("units"),
            F.trim("billed_amount").cast("decimal(13,2)").alias("billed_amount"),
        )
        .dropDuplicates(["file_id", "claim_id", "line_no"])       # same file landed twice
    )


TABLES = {
    "ish_patient": patient,
    "ish_case": case,
    "ish_movement": movement,
    "ish_service": service,
    "ish_service_catalog": service_catalog,
    "claim_837_line": claim_line,
}


def run(spark: SparkSession, settings: Settings) -> dict[str, int]:
    spark.sql(f"CREATE SCHEMA IF NOT EXISTS {settings.schema('silver')}")
    counts = {}
    for name, build in TABLES.items():
        df = build(spark, settings)
        (df.write.format(settings.table_format).mode("overwrite")
           .option("overwriteSchema", "true").saveAsTable(settings.table("silver", name)))
        counts[name] = spark.table(settings.table("silver", name)).count()
    return counts
