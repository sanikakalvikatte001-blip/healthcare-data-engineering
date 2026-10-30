"""Apply an SAP ODP change log to get the current state of a table.

ODP delivers every change as a row with ODQ_CHANGEMODE:
    C = create, U = update (full after-image), D = delete (key fields only)
and an ordering: the request TSN (ODQ_TSN) plus the record number inside the
request (ODQ_RECNO).

Current state = for each business key, keep the latest change; drop the key
if that latest change is a delete. This is the same contract as `APPLY CHANGES`
in Databricks declarative pipelines (keys + sequence_by + apply_as_deletes).
Because it is computed from the full bronze change log, it is idempotent and
order-independent: re-delivered or out-of-order files give the same answer.
"""
from __future__ import annotations

from pyspark.sql import DataFrame, Window
from pyspark.sql import functions as F

ODP_COLUMNS = ["ODQ_CHANGEMODE", "ODQ_ENTITYCNTR", "ODQ_TSN", "ODQ_RECNO"]


def apply_changes(changes: DataFrame, keys: list[str]) -> DataFrame:
    """Return the current image of each key from an ODP change log."""
    latest_first = Window.partitionBy(*keys).orderBy(
        F.col("ODQ_TSN").desc(), F.col("ODQ_RECNO").cast("long").desc()
    )
    return (
        changes.withColumn("_rn", F.row_number().over(latest_first))
        .filter((F.col("_rn") == 1) & (F.col("ODQ_CHANGEMODE") != "D"))
        .withColumnRenamed("ODQ_TSN", "_last_change_tsn")
        .drop("_rn", "ODQ_CHANGEMODE", "ODQ_ENTITYCNTR", "ODQ_RECNO")
    )
