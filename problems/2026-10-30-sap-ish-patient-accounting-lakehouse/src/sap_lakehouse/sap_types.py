"""Column functions for SAP data types as they arrive in flat extracts.

Every function takes and returns a pyspark Column, so it can be used in
select / withColumn and is easy to unit test.
"""
from __future__ import annotations

from pyspark.sql import Column
from pyspark.sql import functions as F


def sap_date(col: str | Column) -> Column:
    """DATS 'YYYYMMDD' -> DateType. '00000000', blanks and impossible dates -> NULL.

    try_to_timestamp keeps this safe when ANSI mode is on (default on
    Databricks serverless), where to_date would raise on '20261332'.
    """
    c = F.trim(F.col(col) if isinstance(col, str) else col)
    return (
        F.when(c.isNull() | c.isin("", "00000000"), F.lit(None).cast("date"))
        .otherwise(F.try_to_timestamp(c, F.lit("yyyyMMdd")).cast("date"))
    )


def sap_timestamp(date_col: str, time_col: str) -> Column:
    """DATS + TIMS ('HHMMSS') -> TimestampType. Missing time = midnight."""
    d = F.trim(F.col(date_col))
    t = F.coalesce(F.nullif(F.trim(F.col(time_col)), F.lit("")), F.lit("000000"))
    return F.when(d.isNull() | d.isin("", "00000000"), F.lit(None).cast("timestamp")).otherwise(
        F.try_to_timestamp(F.concat(d, t), F.lit("yyyyMMddHHmmss"))
    )


def alpha_out(col: str | Column) -> Column:
    """SAP ALPHA conversion, internal -> external: '0004000123' -> '4000123'."""
    c = F.trim(F.col(col) if isinstance(col, str) else col)
    return F.regexp_replace(c, r"^0+(?=.)", "")


def alpha_in(col: str | Column, length: int = 10) -> Column:
    """SAP ALPHA conversion, external -> internal: '4000123' -> '0004000123'.

    Only all-digit values are padded, exactly like the SAP conversion exit.
    """
    c = F.trim(F.col(col) if isinstance(col, str) else col)
    return F.when(c.rlike(r"^[0-9]+$"), F.lpad(c, length, "0")).otherwise(c)


def sap_number(col: str | Column, precision: int = 15, scale: int = 3) -> Column:
    """SAP signed number text -> Decimal.

    Handles padding ('   2.000'), thousands separators ('1,250.00') and the
    SAP trailing minus sign ('125.00-').
    """
    c = F.regexp_replace(F.trim(F.col(col) if isinstance(col, str) else col), ",", "")
    signed = F.when(c.endswith("-"), F.concat(F.lit("-"), c.substr(F.lit(1), F.length(c) - 1))).otherwise(c)
    return F.when(c == "", F.lit(None)).otherwise(signed).cast(f"decimal({precision},{scale})")


def sap_flag(col: str) -> Column:
    """SAP boolean ('X' / ' ') -> BooleanType."""
    return F.coalesce(F.trim(F.col(col)) == "X", F.lit(False))
