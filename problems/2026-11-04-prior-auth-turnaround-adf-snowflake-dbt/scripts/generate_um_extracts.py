"""
Generate synthetic utilization-management (UM) source data and cut it into the
two incremental extracts ADF would land in ADLS.

Source system (Azure SQL "UM platform"):
    um.pa_request        one row per prior authorization request (current state)
    um.pa_status_event   status history: RECEIVED, PENDED_INFO, INFO_RECEIVED,
                         APPROVED, DENIED, PARTIAL_APPROVED, WITHDRAWN

A source row can change after it was first written (priority reclassified,
a decision keyed in wrong and corrected), so every row is generated as a list
of *versions* (value, modified_at). An extract taken at time T only sees the
version that was current at T - exactly what a watermark query on modified_at
returns.

Extract windows (watermark on modified_at). Batch 0 is the initial history
load; after that ADF runs daily, each window re-reading the last hour of the
previous one (overlap so in-flight transactions are never missed):
    batch 0:   modified_at <= 2026-10-15 00:00
    batch n:   CUTOFF_n-1 - 1h < modified_at <= CUTOFF_n,  CUTOFF_n = Oct 15 + n days
    batch 17:  ends 2026-11-01 00:00

Output: data/landing/um/<table>/batch=<n>/part-000.csv  (ADLS folder layout).
100% synthetic - no PHI. Fixed seed so the build is reproducible.
"""
from __future__ import annotations

import csv
import random
from datetime import datetime, timedelta
from pathlib import Path

SEED = 20261104
WINDOW_START = datetime(2026, 7, 1)
INITIAL_CUTOFF = datetime(2026, 10, 15)
DAILY_BATCHES = 17
CUTOFF_2 = INITIAL_CUTOFF + timedelta(days=DAILY_BATCHES)   # 2026-11-01, last extract
OVERLAP = timedelta(hours=1)
N_REQUESTS = 1800

ROOT = Path(__file__).resolve().parents[1]
LANDING = ROOT / "data" / "landing" / "um"

CATEGORIES = {  # service category -> sample CPT/HCPCS codes
    "ADVANCED_IMAGING": ["70553", "72148", "74177"],
    "DME": ["E0601", "K0823", "E0260"],
    "OUTPATIENT_SURGERY": ["29881", "47562", "66984"],
    "BEHAVIORAL_HEALTH": ["90837", "H0035", "90870"],
    "HOME_HEALTH": ["G0299", "G0151", "S9123"],
}
LOBS = ["MEDICAID", "MEDICARE_ADV", "COMMERCIAL"]
CHANNELS = ["FHIR_API", "PORTAL", "FAX"]
DENIAL_REASONS = ["NOT_MED_NECESSARY", "MISSING_DOCUMENTATION", "OUT_OF_NETWORK",
                  "NON_COVERED_BENEFIT"]


def ts(d: datetime) -> str:
    return d.strftime("%Y-%m-%d %H:%M:%S")


def entry_lag(rng: random.Random) -> timedelta:
    """Time between an event happening and the row being written/modified.
    Most are keyed within minutes; ~4% are back-dated entries days later."""
    if rng.random() < 0.04:
        return timedelta(days=rng.uniform(2, 6))
    return timedelta(minutes=rng.uniform(1, 45))


def generate():
    rng = random.Random(SEED)
    requests, events = [], []          # each item: list of (row, modified_at)
    event_seq = 0

    for i in range(1, N_REQUESTS + 1):
        request_id = f"PA{i:06d}"
        received = WINDOW_START + timedelta(
            minutes=rng.randrange(int((CUTOFF_2 - WINDOW_START).total_seconds() // 60)))
        category = rng.choice(list(CATEGORIES))
        priority = "EXPEDITED" if rng.random() < 0.2 else "STANDARD"
        lob = rng.choices(LOBS, weights=[4, 3, 3])[0]

        base = {
            "request_id": request_id,
            "member_id": f"M{rng.randint(1, 900):06d}",
            "requesting_npi": str(1500000000 + rng.randint(1, 400) * 1237),  # fake NPI
            "line_of_business": lob,
            "service_category": category,
            "procedure_code": rng.choice(CATEGORIES[category]),
            "submission_channel": rng.choices(CHANNELS, weights=[3, 5, 2])[0],
            "received_at": ts(received),
        }
        versions = [({**base, "priority": priority}, received + entry_lag(rng))]
        # ~15% of expedited requests are downgraded to STANDARD on clinical
        # review (does not meet the expedited criteria), hours to days later
        if priority == "EXPEDITED" and rng.random() < 0.15:
            versions.append(({**base, "priority": "STANDARD"},
                             received + timedelta(hours=rng.uniform(4, 120))))
        requests.append(versions)

        # ---- status history ------------------------------------------------
        def add_event(status, at, reason=None, corrected_from=None):
            nonlocal event_seq
            event_seq += 1
            row = {"event_id": f"EV{event_seq:07d}", "request_id": request_id,
                   "status": status, "event_at": ts(at), "reason_code": reason or ""}
            mod = at + entry_lag(rng)
            if corrected_from:
                # keyed with the wrong status, fixed by UM QA audit 1-7 days later
                wrong = {**row, "status": corrected_from[0], "reason_code": corrected_from[1]}
                events.append([(wrong, mod), (row, mod + timedelta(days=rng.uniform(1, 7)))])
            else:
                events.append([(row, mod)])

        add_event("RECEIVED", received)
        clock = received
        if rng.random() < 0.25:                       # pended for clinical info
            clock += timedelta(hours=rng.uniform(2, 30))
            add_event("PENDED_INFO", clock, "NEED_CLINICAL_NOTES")
            clock += timedelta(hours=rng.uniform(6, 96))
            if clock < CUTOFF_2:
                add_event("INFO_RECEIVED", clock)

        # decision turnaround (calendar hours after the last clock event)
        if priority == "EXPEDITED":
            hours = rng.lognormvariate(3.3, 0.55)      # median ~27h, tail past 72h
        else:
            hours = rng.lognormvariate(4.3, 0.6)       # median ~74h, tail past 168h
        decision_at = clock + timedelta(hours=hours)
        if decision_at >= CUTOFF_2:
            continue                                    # still open at last extract
        outcome = rng.choices(["APPROVED", "DENIED", "PARTIAL_APPROVED", "WITHDRAWN"],
                              weights=[78, 15, 4, 3])[0]
        reason = rng.choice(DENIAL_REASONS) if outcome in ("DENIED", "PARTIAL_APPROVED") else None
        corrected = None
        if outcome == "APPROVED" and rng.random() < 0.04:
            corrected = ("DENIED", "MISSING_DOCUMENTATION")   # keyed wrong, fixed later
        add_event(outcome, decision_at, reason, corrected)

    return requests, events


def version_as_of(versions, as_of):
    """Return the version current at `as_of` (latest modified_at <= as_of)."""
    current = None
    for row, mod in versions:
        if mod <= as_of:
            current = (row, mod)
    return current


def cut_batches(entities):
    windows = {0: (datetime.min, INITIAL_CUTOFF)}
    for n in range(1, DAILY_BATCHES + 1):
        lo = INITIAL_CUTOFF + timedelta(days=n - 1) - OVERLAP
        windows[n] = (lo, INITIAL_CUTOFF + timedelta(days=n))
    out = {}
    for batch, (lo, hi) in windows.items():
        rows = []
        for versions in entities:
            cur = version_as_of(versions, hi)
            if cur and lo < cur[1] <= hi:
                rows.append({**cur[0], "modified_at": ts(cur[1])})
        out[batch] = rows
    return out


def write(table, batches):
    for batch, rows in batches.items():
        path = LANDING / table / f"batch={batch}" / "part-000.csv"
        path.parent.mkdir(parents=True, exist_ok=True)
        if not rows:
            continue
        rows.sort(key=lambda r: (r["modified_at"], r.get("event_id", r["request_id"])))
        with path.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
    print(f"{table:<16} batch=0: {len(batches[0]):>5} rows, daily batches 1-{DAILY_BATCHES}: "
          f"{sum(len(r) for b, r in batches.items() if b):>5} rows")


if __name__ == "__main__":
    reqs, evts = generate()
    write("pa_request", cut_batches(reqs))
    write("pa_status_event", cut_batches(evts))
