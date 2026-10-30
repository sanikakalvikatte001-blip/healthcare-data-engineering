"""Unit tests for SAP type conversions."""
from datetime import date, datetime
from decimal import Decimal


from sap_lakehouse.sap_types import alpha_in, alpha_out, sap_date, sap_flag, sap_number, sap_timestamp


def one_col(spark, values, fn):
    df = spark.createDataFrame([(v,) for v in values], "v string")
    return [r[0] for r in df.select(fn("v")).collect()]


def test_sap_date_handles_initial_and_invalid_values(spark):
    got = one_col(spark, ["20261028", "00000000", "", None, " 20260901 ", "20261332"], sap_date)
    assert got == [date(2026, 10, 28), None, None, None, date(2026, 9, 1), None]


def test_sap_timestamp_combines_dats_and_tims(spark):
    df = spark.createDataFrame([("20261028", "143005"), ("20261028", ""), ("00000000", "120000")], "d string, t string")
    got = [r[0] for r in df.select(sap_timestamp("d", "t")).collect()]
    assert got == [datetime(2026, 10, 28, 14, 30, 5), datetime(2026, 10, 28), None]


def test_alpha_conversion_round_trip(spark):
    assert one_col(spark, ["0004000123", "0000000000", " 42 ", "ABC12"], alpha_out) == ["4000123", "0", "42", "ABC12"]
    assert one_col(spark, ["4000123", " 42", "ABC12"], alpha_in) == ["0004000123", "0000000042", "ABC12"]


def test_sap_number_padding_thousands_and_trailing_minus(spark):
    got = one_col(spark, ["   2.000", "125.00-", "1,250.50", "", "0.000"], lambda c: sap_number(c, 15, 3))
    assert got == [Decimal("2.000"), Decimal("-125.000"), Decimal("1250.500"), None, Decimal("0.000")]


def test_sap_flag(spark):
    assert one_col(spark, ["X", " X ", "", None, "Y"], sap_flag) == [True, True, False, False, False]
