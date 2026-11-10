"""Step 1 -- decide which diagnosis lines are allowed to count.

Every diagnosis line that comes in gets exactly one ``dx_status``. Lines that
do not count keep a reason, so the audit trail answers "why didn't this HCC
pay?" without anyone re-running the job.

Status precedence (first match wins):
    ORPHAN_DX_NO_HEADER   dx line whose claim header never arrived
    CLAIM_VOIDED          latest version of the claim is a void (freq 8)
    SUPERSEDED_VERSION    an older version replaced by a later one (freq 7)
    UNKNOWN_MEMBER        member not in the enrollment file for the payment year
    CLAIM_DENIED          denied claims are not risk-adjustment eligible
    DOS_OUT_OF_WINDOW     through-date outside the data-collection year
    INELIGIBLE_PROVIDER_TYPE   lab / radiology / DME / ambulance
    INELIGIBLE_SERVICE    procedure is not a face-to-face visit
    INELIGIBLE_BILL_TYPE  facility type not used for risk adjustment (e.g. SNF)
    INVALID_ICD10_FORMAT  not a structurally valid ICD-10-CM code
    NO_HCC_MAPPING        valid code, but not a payment HCC (e.g. I10)
    ACCEPTED              counts toward the member's HCCs
"""
from __future__ import annotations

from pyspark.sql import DataFrame, Window
from pyspark.sql import functions as F

from .config import ModelConfig

# ICD-10-CM shape after removing the dot: letter, digit, then 1-5 alphanumerics.
ICD10_PATTERN = r"^[A-Z][0-9][0-9A-Z]{1,5}$"


def resolve_claim_versions(headers: DataFrame) -> DataFrame:
    """Tag each claim header version as CURRENT, SUPERSEDED or VOIDED.

    Payers send corrections as new versions of the same claim. Only the latest
    version is real; if the latest version is a void, the whole claim is gone.
    """
    by_claim = Window.partitionBy("claim_id")
    latest = Window.partitionBy("claim_id").orderBy(F.col("claim_version").desc())
    return (
        headers
        .withColumn("_is_latest", F.row_number().over(latest) == 1)
        .withColumn(
            "_claim_voided",
            F.max(F.when(F.col("_is_latest") & (F.col("frequency_code") == "8"), True)).over(by_claim),
        )
        .withColumn(
            "version_status",
            F.when(F.col("_claim_voided"), "VOIDED")
             .when(F.col("_is_latest"), "CURRENT")
             .otherwise("SUPERSEDED"),
        )
        .drop("_is_latest", "_claim_voided")
    )


def _in_list(col: str, values) -> F.Column:
    return F.col(col).isin(sorted(values))


def _starts_with_any(col: str, prefixes) -> F.Column:
    cond = F.lit(False)
    for p in prefixes:
        cond = cond | F.col(col).startswith(p)
    return F.coalesce(cond, F.lit(False))   # NULL bill type -> not a match


def classify_source(cfg: ModelConfig):
    """Return a transform that adds ``source_exclusion`` (NULL = eligible source).

    Mirrors the CMS encounter-data filtering idea: professional claims need a
    face-to-face procedure from an acceptable provider type; facility claims
    need an inpatient bill type, or an outpatient bill type plus a
    face-to-face procedure.
    """
    def _transform(headers: DataFrame) -> DataFrame:
        is_prof = F.col("claim_type") == "PROF"
        is_inst = F.col("claim_type") == "INST"
        cpt_ok = _in_list("cpt_code", cfg.acceptable_cpt)
        inpatient = _starts_with_any("bill_type", cfg.inpatient_bill_type_prefixes)
        outpatient = _starts_with_any("bill_type", cfg.outpatient_bill_type_prefixes)
        return headers.withColumn(
            "source_exclusion",
            F.when(F.col("claim_status") != "PAID", "CLAIM_DENIED")
             .when(~F.col("through_dos").between(F.lit(cfg.dos_start), F.lit(cfg.dos_end)), "DOS_OUT_OF_WINDOW")
             .when(is_prof & _in_list("provider_specialty", cfg.excluded_specialties), "INELIGIBLE_PROVIDER_TYPE")
             .when(is_prof & ~F.coalesce(cpt_ok, F.lit(False)), "INELIGIBLE_SERVICE")
             .when(is_inst & inpatient, F.lit(None))
             .when(is_inst & outpatient & ~F.coalesce(cpt_ok, F.lit(False)), "INELIGIBLE_SERVICE")
             .when(is_inst & ~outpatient, "INELIGIBLE_BILL_TYPE")
             .when(~(is_prof | is_inst), "INELIGIBLE_BILL_TYPE"),
        )
    return _transform


def normalize_icd10(col: str = "icd10_raw") -> F.Column:
    """'e11.22 ' -> 'E1122'. Claims systems disagree on dots and case."""
    return F.upper(F.regexp_replace(F.trim(F.col(col)), r"\.", ""))


def build_dx_audit(
    dx_lines: DataFrame,
    headers: DataFrame,
    members: DataFrame,
    dx_to_hcc: DataFrame,
    cfg: ModelConfig,
) -> DataFrame:
    """One row per (diagnosis line x mapped HCC) with a status and, when accepted, the HCC."""
    hdr = headers.transform(resolve_claim_versions).transform(classify_source(cfg))
    enrolled = members.select("member_id", F.lit(True).alias("_enrolled"))

    joined = (
        dx_lines
        .withColumn("icd10", normalize_icd10())
        .join(hdr, ["claim_id", "claim_version"], "left")
        .join(enrolled, "member_id", "left")
        .join(dx_to_hcc.select("icd10", "hcc"), "icd10", "left")
    )

    status = (
        F.when(F.col("claim_type").isNull(), "ORPHAN_DX_NO_HEADER")
         .when(F.col("version_status") == "VOIDED", "CLAIM_VOIDED")
         .when(F.col("version_status") == "SUPERSEDED", "SUPERSEDED_VERSION")
         .when(F.col("_enrolled").isNull(), "UNKNOWN_MEMBER")
         .when(F.col("source_exclusion").isNotNull(), F.col("source_exclusion"))
         .when(~F.coalesce(F.col("icd10").rlike(ICD10_PATTERN), F.lit(False)), "INVALID_ICD10_FORMAT")
         .when(F.col("hcc").isNull(), "NO_HCC_MAPPING")
         .otherwise("ACCEPTED")
    )

    return (
        joined
        .withColumn("dx_status", status)
        # Only accepted lines carry an HCC forward; keeps downstream joins honest.
        .withColumn("hcc", F.when(F.col("dx_status") == "ACCEPTED", F.col("hcc")))
        .select(
            "claim_id", "claim_version", "dx_seq", "member_id", "claim_type", "bill_type",
            "cpt_code", "provider_specialty", "through_dos", "icd10_raw", "icd10", "hcc", "dx_status",
        )
    )
