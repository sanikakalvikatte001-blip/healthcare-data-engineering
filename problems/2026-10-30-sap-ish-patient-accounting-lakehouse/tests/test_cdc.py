"""Unit tests for applying an ODP change log."""
from sap_lakehouse.cdc import apply_changes

COLS = "MANDT string, FALNR string, ENDDT string, ODQ_CHANGEMODE string, ODQ_ENTITYCNTR string, ODQ_TSN string, ODQ_RECNO string"
T1, T2, T3 = "20261026000000000001", "20261027000000000002", "20261028000000000003"


def current(spark, rows):
    df = spark.createDataFrame(rows, COLS)
    return {r.FALNR: r.ENDDT for r in apply_changes(df, ["MANDT", "FALNR"]).collect()}


def test_create_update_delete(spark):
    rows = [
        ("100", "A", "00000000", "C", "1", T1, "1"),
        ("100", "A", "20261027", "U", "1", T2, "1"),   # discharge date arrives
        ("100", "B", "00000000", "C", "1", T1, "2"),
        ("100", "B", None,       "D", "-1", T2, "2"),  # physically deleted in SAP
    ]
    assert current(spark, rows) == {"A": "20261027"}


def test_order_comes_from_tsn_and_recno_not_file_order(spark):
    rows = [
        ("100", "A", "LATEST", "U", "1", T3, "1"),     # newest change listed first
        ("100", "A", "FIRST",  "C", "1", T1, "1"),
        ("100", "A", "SECOND", "U", "1", T2, "1"),
        ("100", "C", "R9",     "U", "1", T2, "9"),     # same TSN: RECNO compared as a number,
        ("100", "C", "R10",    "U", "1", T2, "10"),   # so 10 > 9 (text sort would pick 9)
    ]
    assert current(spark, rows) == {"A": "LATEST", "C": "R10"}


def test_redelivered_rows_and_recreate_after_delete(spark):
    rows = [
        ("100", "A", "X", "C", "1", T1, "1"),
        ("100", "A", "X", "C", "1", T1, "1"),          # same row delivered twice
        ("100", "B", "1", "C", "1", T1, "2"),
        ("100", "B", None, "D", "-1", T2, "1"),
        ("100", "B", "2", "C", "1", T3, "1"),          # key re-created after delete
    ]
    assert current(spark, rows) == {"A": "X", "B": "2"}


def test_clients_are_separate_keys(spark):
    df = spark.createDataFrame([("100", "A", "P", "C", "1", T1, "1"), ("200", "A", "T", "C", "1", T2, "1")], COLS)
    got = {(r.MANDT, r.FALNR): r.ENDDT for r in apply_changes(df, ["MANDT", "FALNR"]).collect()}
    assert got == {("100", "A"): "P", ("200", "A"): "T"}
