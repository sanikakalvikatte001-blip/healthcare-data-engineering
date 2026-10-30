"""Generate synthetic SAP IS-H extracts and an 837 claim-line file.

This is a helper only: it writes the *landing zone* files the PySpark pipeline
ingests. Everything is synthetic -- no real patients, cases or providers.

It imitates what an ODP / SLT extraction from SAP IS-H really looks like:

* tables NPAT (patient), NFAL (case), NBEW (movement), NLEI (service), plus a
  simplified service master (NTPK) carrying a customer field ZZCPT for the
  SAP service -> CPT crosswalk
* every field is text; dates are DATS ``YYYYMMDD`` with ``00000000`` meaning
  "no date"; times are TIMS ``HHMMSS``; keys are NUMC with leading zeros
* quantities in SAP QUAN format with padding (``"   2.000"``)
* ODP change columns: ODQ_CHANGEMODE (C/U/D), ODQ_ENTITYCNTR, ODQ_TSN
* one full extract (2026-10-26) followed by one delta extract (2026-10-28)
* rows from test client 200 mixed into the production client 100 files

Defects are planted on purpose so the reconciliation has known answers. The
counts are written to data/planted_defects.json and asserted by the tests.

Usage:  python tools/generate_synthetic_extracts.py [--out data]
"""
from __future__ import annotations

import argparse
import csv
import json
import random
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path

SEED = 20261030
CLIENT, TEST_CLIENT, EINRI = "100", "200", "1000"
TSN_FULL = "20261026220000000001"     # ODP request TSN of the initial load
TSN_DELTA = "20261028220000000002"    # ODP request TSN of the delta load
FULL_EXTRACT_DATE = date(2026, 10, 26)
DELTA_EXTRACT_DATE = date(2026, 10, 28)
CLAIMS_CUTOFF = FULL_EXTRACT_DATE     # billing run bills cases discharged by this date

# Simplified service master: LEIST, description, CPT (customer field ZZCPT), price.
CATALOG = [
    ("E00223", "Initial hospital care, high",      "99223",   420.00),
    ("E00232", "Subsequent hospital care",         "99232",   160.00),
    ("E00238", "Hospital discharge day",           "99238",   150.00),
    ("E00284", "ED visit, moderate",               "99284",   520.00),
    ("E00285", "ED visit, high",                   "99285",   780.00),
    ("E00213", "Office visit, established",        "99213",    95.00),
    ("L80053", "Comprehensive metabolic panel",    "80053",    48.00),
    ("L85025", "CBC with differential",            "85025",    32.00),
    ("L36415", "Venipuncture",                     "36415",    12.00),
    ("R71046", "Chest x-ray, 2 views",             "71046",    85.00),
    ("R73560", "Knee x-ray, 2 views",              "73560",    78.00),
    ("C93000", "ECG with interpretation",          "93000",    60.00),
    ("C93306", "Echocardiogram, complete",         "93306",   890.00),
    ("O27447", "Total knee arthroplasty",          "27447", 18500.00),
    ("P97110", "Therapeutic exercise, 15 min",     "97110",    55.00),
]
PRICE = {leist: price for leist, _, _, price in CATALOG}
CPT = {leist: cpt for leist, _, cpt, _ in CATALOG}

ODQ_COLS = ["ODQ_CHANGEMODE", "ODQ_ENTITYCNTR", "ODQ_TSN", "ODQ_RECNO"]


def dats(d: date | None) -> str:
    return d.strftime("%Y%m%d") if d else "00000000"


def quan(q: int) -> str:
    """SAP QUAN as it appears in flat extracts: right-aligned, 3 decimals."""
    return f"{q:8.3f}"


class Extract:
    """Collects rows for one SAP table across the full and delta files."""

    def __init__(self, table: str, columns: list[str]):
        self.table, self.columns = table, columns
        self.rows: dict[str, list[dict]] = {"full": [], "delta": []}

    def add(self, load: str, mode: str, **fields):
        row = {c: fields.get(c, "") for c in self.columns}
        row["MANDT"] = fields.get("MANDT", CLIENT)
        row["ODQ_CHANGEMODE"] = mode
        row["ODQ_ENTITYCNTR"] = "-1" if mode == "D" else "1"
        row["ODQ_TSN"] = TSN_FULL if load == "full" else TSN_DELTA
        row["ODQ_RECNO"] = str(len(self.rows[load]) + 1)
        self.rows[load].append(row)

    def write(self, root: Path):
        folder = root / "landing" / "sap_ish" / self.table
        folder.mkdir(parents=True, exist_ok=True)
        for load, stamp in (("full", FULL_EXTRACT_DATE), ("delta", DELTA_EXTRACT_DATE)):
            if not self.rows[load]:
                continue
            path = folder / f"{self.table}_{stamp:%Y%m%d}_{load}.csv"
            with path.open("w", newline="") as fh:
                w = csv.DictWriter(fh, fieldnames=["MANDT", *self.columns, *ODQ_COLS])
                w.writeheader()
                w.writerows(self.rows[load])


def main(out: Path) -> dict:
    rng = random.Random(SEED)

    npat = Extract("NPAT", ["PATNR", "GBDAT", "GSCHL", "PSTLZ"])
    nfal = Extract("NFAL", ["EINRI", "FALNR", "PATNR", "FALAR", "BEGDT", "ENDDT", "STORN"])
    nbew = Extract("NBEW", ["EINRI", "FALNR", "LFDNR", "BEWTY", "BWIDT", "BWIZT", "ORGFA", "STORN"])
    nlei = Extract("NLEI", ["EINRI", "LNRLS", "FALNR", "TARIF", "LEIST", "IBGDT", "IMENG", "STORN"])
    ntpk = Extract("NTPK", ["EINRI", "TARIF", "LEIST", "KTXT", "ZZCPT", "PREIS"])

    for leist, text, cpt, price in CATALOG:
        ntpk.add("full", "C", EINRI=EINRI, TARIF="HOSP", LEIST=leist, KTXT=text,
                 ZZCPT=cpt, PREIS=f"{price:.2f}")

    # ---- patients -----------------------------------------------------------
    patients = [f"{100000 + i:010d}" for i in range(1, 401)]
    for i, patnr in enumerate(patients):
        birth = date(1940, 1, 1) + timedelta(days=rng.randint(0, 27_000))
        npat.add("full", "C", PATNR=patnr,
                 GBDAT="00000000" if i % 150 == 7 else dats(birth),   # a few unknown DOBs
                 GSCHL=rng.choice("12"), PSTLZ=f"{rng.randint(10000, 99999)}")

    # ---- cases, movements, services ----------------------------------------
    cases = []                                  # dicts with case attributes
    services = {}                               # (falnr, leist, date) -> qty (full extract)
    delta_services = {}                         # charges posted after the full extract
    for n in range(600):
        falnr = f"{4000001 + n:010d}"
        inpatient = rng.random() < 0.40
        dept = rng.choice(["MED", "CARD", "ORTH"]) if inpatient else rng.choice(["ER", "ER", "MEDC"])
        start = date(2026, 9, 1) + timedelta(days=rng.randint(0, 54 if inpatient else 55))
        los = rng.randint(1, 7) if inpatient else 0
        end = start + timedelta(days=los)
        cases.append(dict(falnr=falnr, patnr=rng.choice(patients), inpatient=inpatient,
                          dept=dept, start=start, end=end))

        # charges by date for this case
        chg: dict[tuple, int] = defaultdict(int)
        if inpatient:
            chg[("E00223", start)] += 1
            for k in range(1, los):
                chg[("E00232", start + timedelta(days=k))] += 1
            if los:
                chg[("E00238", end)] += 1
            for k in range(los + 1):
                if k == 0 or rng.random() < 0.35:
                    d = start + timedelta(days=k)
                    chg[("L80053", d)] += 1; chg[("L85025", d)] += 1; chg[("L36415", d)] += 1
            if dept == "CARD":
                chg[("C93000", start)] += 1
                chg[("C93306", start + timedelta(days=min(1, los)))] += 1
            elif dept == "ORTH":
                chg[("O27447", start)] += 1
                chg[("R73560", start + timedelta(days=min(1, los)))] += 1
                for k in range(1, los + 1):
                    chg[("P97110", start + timedelta(days=k))] += 2
            else:
                chg[("R71046", start)] += 1
        else:
            if dept == "ER":
                chg[(rng.choice(["E00284", "E00284", "E00285"]), start)] += 1
                for leist, p in (("R71046", .4), ("C93000", .3), ("L80053", .5)):
                    if rng.random() < p:
                        chg[(leist, start)] += 1
            else:
                chg[("E00213", start)] += 1
                if rng.random() < 0.5:
                    chg[("L85025", start)] += 1; chg[("L36415", start)] += 1

        for (leist, d), q in chg.items():
            target = services if d <= FULL_EXTRACT_DATE else delta_services
            target[(falnr, leist, d)] = q

    # ---- planted case-level changes ----------------------------------------
    in_scope = [c for c in cases if c["end"] <= CLAIMS_CUTOFF]
    by_case = defaultdict(list)
    for key in services:
        by_case[key[0]].append(key)

    # 1 outpatient case cancelled after it was billed (case-level storno).
    cancelled_case = next(c for c in in_scope if not c["inpatient"] and len(by_case[c["falnr"]]) == 3)

    # ---- write NFAL / NBEW ---------------------------------------------------
    for c in cases:
        discharged_full = c["end"] <= FULL_EXTRACT_DATE
        nfal.add("full", "C", EINRI=EINRI, FALNR=c["falnr"], PATNR=c["patnr"],
                 FALAR="1" if c["inpatient"] else "2", BEGDT=dats(c["start"]),
                 ENDDT=dats(c["end"]) if discharged_full else "00000000")
        if c["inpatient"]:
            nbew.add("full", "C", EINRI=EINRI, FALNR=c["falnr"], LFDNR="00001", BEWTY="1",
                     BWIDT=dats(c["start"]), BWIZT=f"{rng.randint(0, 23):02d}{rng.randint(0, 59):02d}00",
                     ORGFA=c["dept"])
            discharge = ("full" if discharged_full else
                         "delta" if c["end"] <= DELTA_EXTRACT_DATE else None)
            if discharge:
                nbew.add(discharge, "C", EINRI=EINRI, FALNR=c["falnr"], LFDNR="00002", BEWTY="2",
                         BWIDT=dats(c["end"]), BWIZT=f"{rng.randint(8, 18):02d}0000", ORGFA=c["dept"])
                if discharge == "delta":   # case end date arrives as an NFAL update
                    nfal.add("delta", "U", EINRI=EINRI, FALNR=c["falnr"], PATNR=c["patnr"], FALAR="1",
                             BEGDT=dats(c["start"]), ENDDT=dats(c["end"]))
        else:
            nbew.add("full", "C", EINRI=EINRI, FALNR=c["falnr"], LFDNR="00001", BEWTY="4",
                     BWIDT=dats(c["start"]), BWIZT=f"{rng.randint(7, 20):02d}{rng.randint(0, 59):02d}00",
                     ORGFA=c["dept"])

    c = cancelled_case
    nfal.add("delta", "U", EINRI=EINRI, FALNR=c["falnr"], PATNR=c["patnr"], FALAR="2",
             BEGDT=dats(c["start"]), ENDDT=dats(c["end"]), STORN="X")

    # A case created in error in the full load and physically deleted in SAP.
    nfal.add("full", "C", EINRI=EINRI, FALNR="0004999999", PATNR=patients[0], FALAR="2",
             BEGDT="20261020", ENDDT="20261020")
    nfal.add("delta", "D", EINRI=EINRI, FALNR="0004999999")

    # Test client 200 rows that reuse production case numbers.
    for c in cases[:5]:
        nfal.add("full", "C", MANDT=TEST_CLIENT, EINRI=EINRI, FALNR=c["falnr"], PATNR=c["patnr"],
                 FALAR="2", BEGDT=dats(c["start"]), ENDDT=dats(c["start"]))

    # ---- write NLEI (full) ---------------------------------------------------
    lnrls_of = {}
    next_lnrls = 7000000001
    for key in sorted(services, key=lambda k: (k[0], k[2], k[1])):
        lnrls_of[key] = f"{next_lnrls:010d}"; next_lnrls += 1
        falnr, leist, d = key
        nlei.add("full", "C", EINRI=EINRI, LNRLS=lnrls_of[key], FALNR=falnr, TARIF="HOSP",
                 LEIST=leist, IBGDT=dats(d), IMENG=quan(services[key]))
    for key in list(services)[:8]:   # test client copies of real postings
        nlei.add("full", "C", MANDT=TEST_CLIENT, EINRI=EINRI, LNRLS=lnrls_of[key], FALNR=key[0],
                 TARIF="HOSP", LEIST=key[1], IBGDT=dats(key[2]), IMENG=quan(9))

    # ---- planted service-level defects (disjoint samples) --------------------
    in_scope_ids = {c["falnr"] for c in in_scope}
    pool = sorted(k for k in services if k[0] in in_scope_ids and k[0] != cancelled_case["falnr"])
    rng.shuffle(pool)
    take = lambda n: [pool.pop() for _ in range(n)]
    dropped, amount_wrong = take(6), take(4)
    qty_update, qty_storno, cancelled = take(2), take(3), take(3)

    def nlei_row(key, qty, storn="", lnrls=None):
        return dict(EINRI=EINRI, LNRLS=lnrls or lnrls_of[key], FALNR=key[0], TARIF="HOSP",
                    LEIST=key[1], IBGDT=dats(key[2]), IMENG=quan(qty), STORN=storn)

    # Quantity corrected in place. The first key is corrected twice in the same
    # delta; the later record (higher ODQ_RECNO) must win.
    nlei.add("delta", "U", **nlei_row(qty_update[0], services[qty_update[0]] + 3))
    for key in qty_update:
        nlei.add("delta", "U", **nlei_row(key, services[key] + 1))
    # Quantity corrected the SAP way: cancel the posting, re-post with a new LNRLS.
    for key in qty_storno:
        nlei.add("delta", "U", **nlei_row(key, services[key], storn="X"))
        nlei.add("delta", "C", **nlei_row(key, services[key] + 1, lnrls=f"{next_lnrls:010d}"))
        next_lnrls += 1
    # Service cancelled after billing.
    for key in cancelled:
        nlei.add("delta", "U", **nlei_row(key, services[key], storn="X"))
    # Late charges: posted on billed cases after the billing run.
    late = []
    for c in in_scope:
        if len(late) == 7:
            break
        key = (c["falnr"], "C93000", c["end"])
        if key not in services and c["falnr"] != cancelled_case["falnr"]:
            late.append(key)
            nlei.add("delta", "C", **nlei_row(key, 1, lnrls=f"{next_lnrls:010d}"))
            next_lnrls += 1
    # Charges for days after the full extract on cases still in house.
    for key, q in sorted(delta_services.items()):
        nlei.add("delta", "C", **nlei_row(key, q, lnrls=f"{next_lnrls:010d}"))
        next_lnrls += 1

    # Unchanged patients re-sent in the delta (ODP re-delivery).
    for patnr in patients[:10]:
        src = next(r for r in npat.rows["full"] if r["PATNR"] == patnr)
        npat.add("delta", "U", **{k: src[k] for k in ("PATNR", "GBDAT", "GSCHL", "PSTLZ")})

    # ---- 837 claim lines from the billing run --------------------------------
    claim_rows = []
    line_no = defaultdict(int)

    def claim(claim_id, cpt, d, units, amount):
        line_no[claim_id] += 1
        claim_rows.append(dict(file_id="ISA000777001", claim_id=claim_id,
                               line_no=str(line_no[claim_id]), cpt_code=cpt,
                               service_from_date=dats(d), units=str(units),
                               billed_amount=f"{amount:.2f}"))

    for key in sorted(k for k in services if k[0] in in_scope_ids):
        if key in dropped:
            continue
        falnr, leist, d = key
        amount = services[key] * PRICE[leist] * (1.10 if key in amount_wrong else 1)
        claim(falnr.lstrip("0"), CPT[leist], d, services[key], round(amount, 2))  # CLM01 = case no
    # Claim lines with no SAP charge behind them.
    for c in in_scope[:2]:
        claim(c["falnr"].lstrip("0"), "99285", c["start"], 1, 780.00)
    claim("9999901", "99214", date(2026, 10, 1), 1, 140.00)
    claim("9999902", "99214", date(2026, 10, 2), 1, 140.00)
    assert all(("E00285", c["start"]) not in [(k[1], k[2]) for k in by_case[c["falnr"]]]
               for c in in_scope[:2])

    claims_dir = out / "landing" / "claims_837"
    claims_dir.mkdir(parents=True, exist_ok=True)
    with (claims_dir / "claim_lines_20261027.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(claim_rows[0]))
        w.writeheader(); w.writerows(claim_rows)

    for ext in (npat, nfal, nbew, nlei, ntpk):
        ext.write(out)

    planted = {
        "NOT_BILLED": len(dropped) + len(late),
        "AMOUNT_MISMATCH": len(amount_wrong),
        "UNITS_MISMATCH": len(qty_update) + len(qty_storno),
        "CANCELLED_BUT_BILLED": len(cancelled) + len(by_case[cancelled_case["falnr"]]),
        "BILLED_NOT_IN_SAP": 4,
        "cancelled_case": cancelled_case["falnr"],
        "deleted_case": "0004999999",
        "claim_lines": len(claim_rows),
        "cases_client_100": len(cases) + 1,
        "cases_in_scope": len(in_scope),
    }
    (out / "planted_defects.json").write_text(json.dumps(planted, indent=2) + "\n")
    return planted


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(Path(__file__).resolve().parents[1] / "data"))
    print(json.dumps(main(Path(ap.parse_args().out)), indent=2))
