"""Model configuration and reference tables.

Everything that changes from one payment year (or model version) to the next
lives in ``model/`` as data -- the code never hard-codes an HCC number, a CPT
code or a coefficient. Swapping V24 for V28, or PY2026 for PY2027, is a
config change, not a code change.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import date
from pathlib import Path

from pyspark.sql import DataFrame, SparkSession
from pyspark.sql import types as T


@dataclass(frozen=True)
class Interaction:
    """A disease interaction: fires when the member has >=1 payment HCC from EVERY group."""
    name: str
    coefficient: float
    groups: tuple[tuple[int, ...], ...]


@dataclass(frozen=True)
class CountVariable:
    """Payment-HCC count variable (e.g. D6 = exactly six payment HCCs)."""
    name: str
    min_hccs: int
    max_hccs: int
    coefficient: float


@dataclass(frozen=True)
class ModelConfig:
    model_version: str
    payment_year: int
    dos_start: date
    dos_end: date
    age_as_of: date
    normalization_factor: float
    coding_intensity_adjustment: float
    acceptable_cpt: frozenset[str]
    excluded_specialties: frozenset[str]
    inpatient_bill_type_prefixes: tuple[str, ...]
    outpatient_bill_type_prefixes: tuple[str, ...]
    interactions: tuple[Interaction, ...]
    count_variables: tuple[CountVariable, ...]


@dataclass(frozen=True)
class ReferenceTables:
    dx_to_hcc: DataFrame
    hcc_coefficients: DataFrame
    hierarchy: DataFrame
    demographic_factors: DataFrame
    interactions: DataFrame       # long form: interaction, group_idx, hcc, n_groups, coefficient
    count_variables: DataFrame


def load_config(model_dir: str | Path) -> ModelConfig:
    raw = json.loads((Path(model_dir) / "model_config.json").read_text())
    return ModelConfig(
        model_version=raw["model_version"],
        payment_year=int(raw["payment_year"]),
        dos_start=date.fromisoformat(raw["dos_start"]),
        dos_end=date.fromisoformat(raw["dos_end"]),
        age_as_of=date.fromisoformat(raw["age_as_of"]),
        normalization_factor=float(raw["normalization_factor"]),
        coding_intensity_adjustment=float(raw["coding_intensity_adjustment"]),
        acceptable_cpt=frozenset(raw["acceptable_cpt"]),
        excluded_specialties=frozenset(raw["excluded_specialties"]),
        inpatient_bill_type_prefixes=tuple(raw["inpatient_bill_type_prefixes"]),
        outpatient_bill_type_prefixes=tuple(raw["outpatient_bill_type_prefixes"]),
        interactions=tuple(
            Interaction(i["name"], float(i["coefficient"]), tuple(tuple(g) for g in i["groups"]))
            for i in raw["interactions"]
        ),
        count_variables=tuple(
            CountVariable(c["name"], int(c["min_hccs"]), int(c["max_hccs"]), float(c["coefficient"]))
            for c in raw["count_variables"]
        ),
    )


_SCHEMAS = {
    "dx_to_hcc": "icd10 STRING, hcc INT, icd10_description STRING",
    "hcc_coefficients": "hcc INT, hcc_label STRING, coefficient DOUBLE",
    "hierarchy": "parent_hcc INT, child_hcc INT",
    "demographic_factors": "sex STRING, age_lo INT, age_hi INT, factor DOUBLE",
}


def _read_ref(spark: SparkSession, model_dir: Path, name: str) -> DataFrame:
    return spark.read.csv(str(model_dir / f"{name}.csv"), header=True, schema=_SCHEMAS[name]).cache()


def load_reference_tables(spark: SparkSession, model_dir: str | Path, cfg: ModelConfig) -> ReferenceTables:
    model_dir = Path(model_dir)
    refs = {name: _read_ref(spark, model_dir, name) for name in _SCHEMAS}

    interactions = spark.createDataFrame(
        [
            (ix.name, gi, hcc, len(ix.groups), ix.coefficient)
            for ix in cfg.interactions
            for gi, group in enumerate(ix.groups)
            for hcc in group
        ],
        "interaction STRING, group_idx INT, hcc INT, n_groups INT, coefficient DOUBLE",
    )
    count_vars = spark.createDataFrame(
        [(c.name, c.min_hccs, c.max_hccs, c.coefficient) for c in cfg.count_variables],
        "count_variable STRING, min_hccs INT, max_hccs INT, count_coefficient DOUBLE",
    )

    tables = ReferenceTables(interactions=interactions, count_variables=count_vars, **refs)
    validate_reference_tables(tables)
    return tables


def validate_reference_tables(ref: ReferenceTables) -> None:
    """Fail fast on reference-data mistakes that would silently mis-score members.

    The tables are tiny, so collecting them to the driver is fine.
    """
    coef_hccs = {r.hcc for r in ref.hcc_coefficients.select("hcc").collect()}
    mapped_hccs = {r.hcc for r in ref.dx_to_hcc.select("hcc").distinct().collect()}
    missing = mapped_hccs - coef_hccs
    if missing:
        raise ValueError(f"HCCs mapped from ICD-10 but with no coefficient: {sorted(missing)}")

    dup_icd = ref.dx_to_hcc.groupBy("icd10", "hcc").count().where("count > 1").collect()
    if dup_icd:
        raise ValueError(f"Duplicate ICD-10 -> HCC rows: {[(r.icd10, r.hcc) for r in dup_icd]}")

    # The hierarchy must be transitively closed (if A trumps B and B trumps C, the
    # table must also say A trumps C). Otherwise a member with A and C but no B
    # would keep both -- a classic overpayment bug.
    edges = {(r.parent_hcc, r.child_hcc) for r in ref.hierarchy.collect()}
    gaps = {(a, d) for (a, b) in edges for (c, d) in edges if b == c and (a, d) not in edges}
    if gaps:
        raise ValueError(f"Hierarchy is not transitively closed; missing parent->child: {sorted(gaps)}")

    # Demographic bands must not overlap for the same sex.
    bands = sorted((r.sex, r.age_lo, r.age_hi) for r in ref.demographic_factors.collect())
    for (s1, _, hi1), (s2, lo2, _) in zip(bands, bands[1:]):
        if s1 == s2 and lo2 <= hi1:
            raise ValueError(f"Overlapping demographic age bands for sex {s1}")


# Input schemas -- declared explicitly so a bad file fails loudly instead of
# being silently inferred as strings.
MEMBER_SCHEMA = T.StructType([
    T.StructField("member_id", T.StringType(), False),
    T.StructField("sex", T.StringType(), False),
    T.StructField("birth_date", T.DateType(), False),
])

CLAIM_HEADER_SCHEMA = T.StructType([
    T.StructField("claim_id", T.StringType(), False),
    T.StructField("claim_version", T.IntegerType(), False),
    T.StructField("frequency_code", T.StringType(), False),   # 1 original, 7 replacement, 8 void
    T.StructField("member_id", T.StringType(), False),
    T.StructField("claim_type", T.StringType(), False),       # PROF | INST
    T.StructField("bill_type", T.StringType(), True),         # INST only, e.g. 111, 131
    T.StructField("cpt_code", T.StringType(), True),
    T.StructField("provider_specialty", T.StringType(), True),
    T.StructField("from_dos", T.DateType(), False),
    T.StructField("through_dos", T.DateType(), False),
    T.StructField("claim_status", T.StringType(), False),     # PAID | DENIED
])

CLAIM_DX_SCHEMA = T.StructType([
    T.StructField("claim_id", T.StringType(), False),
    T.StructField("claim_version", T.IntegerType(), False),
    T.StructField("dx_seq", T.IntegerType(), False),
    T.StructField("icd10_raw", T.StringType(), True),
])
