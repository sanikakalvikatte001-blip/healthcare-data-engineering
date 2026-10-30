"""Integration tests: full bronze -> silver -> gold run on the synthetic extracts."""
from decimal import Decimal

from pyspark.sql import functions as F

from sap_lakehouse import bronze


def tbl(spark, settings, layer, name):
    return spark.table(settings.table(layer, name))


def test_recon_finds_every_planted_defect(spark, settings, built, planted):
    rec = tbl(spark, settings, "gold", "recon_charge_vs_claim")
    got = {r.recon_status: r["count"] for r in rec.groupBy("recon_status").count().collect()}
    for status in ("NOT_BILLED", "AMOUNT_MISMATCH", "UNITS_MISMATCH",
                   "CANCELLED_BUT_BILLED", "BILLED_NOT_IN_SAP"):
        assert got[status] == planted[status], status
    # every claim line is accounted for exactly once
    assert rec.agg(F.sum("claim_lines")).first()[0] == planted["claim_lines"]
    assert got["MATCHED"] == planted["claim_lines"] - sum(
        planted[s] for s in ("AMOUNT_MISMATCH", "UNITS_MISMATCH", "CANCELLED_BUT_BILLED", "BILLED_NOT_IN_SAP"))


def test_test_client_and_deleted_case_are_excluded(spark, settings, built, planted):
    case = tbl(spark, settings, "silver", "ish_case")
    assert case.count() == planted["cases_client_100"] - 1
    assert case.filter(F.col("case_id") == planted["deleted_case"]).count() == 0
    # client 200 rows were posted with quantity 9; none may reach silver
    assert tbl(spark, settings, "silver", "ish_service").filter("quantity = 9").count() == 0


def test_cancelled_case_cascades_to_its_charges(spark, settings, built, planted):
    chg = tbl(spark, settings, "gold", "fact_charge").filter(F.col("case_id") == planted["cancelled_case"])
    assert chg.count() == 3 and chg.filter("is_cancelled").count() == 3
    enc = tbl(spark, settings, "gold", "fact_encounter").filter(F.col("case_id") == planted["cancelled_case"]).first()
    assert enc.is_cancelled and enc.in_billing_scope


def test_storno_and_repost_is_a_units_change_not_two_errors(spark, settings, built):
    rec = tbl(spark, settings, "gold", "recon_charge_vs_claim")
    reposted = rec.filter("sap_active_postings = 1 AND sap_cancelled_postings = 1")
    assert reposted.count() == 3
    assert {r.recon_status for r in reposted.collect()} == {"UNITS_MISMATCH"}


def test_latest_update_wins_within_one_delta(spark, settings, built):
    # LNRLS 7000003057 was updated twice in the delta: qty 4, then qty 2 (later record).
    svc = tbl(spark, settings, "silver", "ish_service").filter("service_doc_id = '7000003057'").first()
    assert svc.quantity == Decimal("2.000")


def test_claim_ids_join_to_sap_cases_only_after_alpha_conversion(spark, settings, built):
    clm = tbl(spark, settings, "silver", "claim_837_line")
    case = tbl(spark, settings, "silver", "ish_case")
    assert clm.join(case, clm.claim_id == case.case_id).count() == 0     # '4000001' != '0004000001'
    assert clm.join(case, "case_id").count() == clm.count() - 2           # 2 unknown claim ids


def test_encounter_facts(spark, settings, built):
    enc = tbl(spark, settings, "gold", "fact_encounter")
    assert enc.filter("length_of_stay_days < 0").count() == 0
    assert enc.filter("case_type = 'OUTPATIENT' AND length_of_stay_days IS NOT NULL").count() == 0
    assert enc.filter("is_open AND in_billing_scope").count() == 0
    assert enc.filter("admit_ts IS NULL OR admitting_department IS NULL").count() == 0
    # closed inpatient stays have a discharge movement on the case end date
    closed_ip = enc.filter("case_type = 'INPATIENT' AND NOT is_open")
    assert closed_ip.filter("to_date(discharge_ts) <> case_end_date OR discharge_ts IS NULL").count() == 0


def test_bronze_rerun_is_idempotent(spark, settings, built):
    before = tbl(spark, settings, "bronze", "ish_nlei").count()
    assert bronze.run(spark, settings) == {t: 0 for t in bronze.SOURCES}
    assert tbl(spark, settings, "bronze", "ish_nlei").count() == before
