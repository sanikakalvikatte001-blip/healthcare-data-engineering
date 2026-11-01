"""Map one ORU^R01 message to flat, LOINC-coded observation rows.

Each OBX becomes either an ``Observation`` or a ``Reject`` with a reason code,
so one bad result never blocks the rest of the panel.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from .hl7 import Message, Segment
from .reference import ReferenceData

# Reason codes used in rejects.csv
NOT_ORU = "NOT_ORU_R01"
MISSING_MRN = "MISSING_MRN"
UNMAPPED_CODE = "UNMAPPED_CODE"
NON_NUMERIC = "NON_NUMERIC_VALUE"
UNIT_NOT_CONVERTIBLE = "UNIT_NOT_CONVERTIBLE"
BAD_TIMESTAMP = "BAD_TIMESTAMP"

NUMERIC_TYPES = {"NM", "SN"}
_DTM = re.compile(r"^(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?(\d{2})?(?:\.\d+)?([+-]\d{4})?$")
_COMPARATOR_NM = re.compile(r"^\s*(<=|>=|<|>)\s*(-?\d+(?:\.\d+)?)\s*$")


@dataclass
class Observation:
    sending_facility: str
    message_control_id: str
    message_datetime_utc: str
    mrn: str
    mrn_assigning_authority: str
    accession_number: str
    order_code: str
    obx_set_id: int
    loinc: str
    source_code: str
    source_code_system: str
    observation_text: str
    value_type: str
    comparator: str
    value_numeric: float | None
    value_text: str
    unit: str
    source_value: str
    source_unit: str
    reference_range: str
    abnormal_flag: str
    result_status: str
    observed_at_utc: str


@dataclass
class Reject:
    sending_facility: str
    message_control_id: str
    obx_set_id: int | None
    reason: str
    detail: str


def parse_hl7_ts(value: str, default_tz: ZoneInfo) -> datetime:
    """HL7 DTM -> aware UTC datetime. Missing offset uses the lab's local zone."""
    m = _DTM.match(value.strip())
    if not m:
        raise ValueError(f"unparseable HL7 timestamp {value!r}")
    y, mo, d, h, mi, s, off = m.groups()
    local = datetime(int(y), int(mo or 1), int(d or 1), int(h or 0), int(mi or 0), int(s or 0))
    if off:
        sign = 1 if off[0] == "+" else -1
        tz = timezone(sign * timedelta(hours=int(off[1:3]), minutes=int(off[3:5])))
        local = local.replace(tzinfo=tz)
    else:
        local = local.replace(tzinfo=default_tz)
    return local.astimezone(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def pick_mrn(pid: Segment) -> tuple[str, str]:
    """PID-3 repeats (MRN, SSN-like ids, payer ids...). Take the type 'MR' one."""
    for rep in range(1, len(pid.repetitions(3)) + 1):
        if pid.get(3, 5, rep=rep).upper() == "MR" and pid.get(3, 1, rep=rep):
            return pid.get(3, 1, rep=rep), pid.get(3, 4, rep=rep)
    return "", ""


def parse_value(value_type: str, obx: Segment) -> tuple[str, float | None, str]:
    """Return (comparator, numeric, text) for OBX-5; raises ValueError for bad NM."""
    if value_type == "SN":                       # <comparator>^<num1>
        comp, num = obx.get(5, 1), obx.get(5, 2)
        return comp, float(num), f"{comp}{num}"
    if value_type == "NM":
        raw = obx.get(5)
        try:
            return "", float(raw), raw
        except ValueError:
            # Labs frequently send "<0.01" as NM; accept it as a comparator.
            m = _COMPARATOR_NM.match(raw)
            if m:
                return m.group(1), float(m.group(2)), raw
            raise ValueError(f"OBX-5 {raw!r} is not numeric") from None
    if value_type in ("CWE", "CE"):
        return "", None, obx.get(5, 2) or obx.get(5, 1)
    # ST / TX / FT: join repetitions (long free-text results repeat OBX-5)
    return "", None, " ".join(r for r in (obx.get(5, rep=i) for i in
                                          range(1, len(obx.repetitions(5)) + 1)) if r)


def map_oru(msg: Message, ref: ReferenceData) -> tuple[list[Observation], list[Reject]]:
    facility = msg.msh.get(4) or msg.msh.get(3)
    ctl = msg.control_id
    tz = ref.lab_timezones.get(facility, ZoneInfo("UTC"))

    if msg.message_type != "ORU^R01":
        return [], [Reject(facility, ctl, None, NOT_ORU, f"message type {msg.message_type}")]

    pid = msg.first("PID")
    mrn, auth = pick_mrn(pid) if pid else ("", "")
    if not mrn:
        n = len(msg.all("OBX"))
        return [], [Reject(facility, ctl, None, MISSING_MRN, f"no PID-3 with type MR; {n} OBX skipped")]

    try:
        msg_dt = _iso(parse_hl7_ts(msg.msh.get(7), tz))
    except ValueError as exc:
        return [], [Reject(facility, ctl, None, BAD_TIMESTAMP, f"MSH-7: {exc}")]

    rows: list[Observation] = []
    rejects: list[Reject] = []
    obr: Segment | None = None
    for seg in msg.segments:
        if seg.name == "OBR":
            obr = seg
            continue
        if seg.name != "OBX" or obr is None:
            continue

        set_id = int(seg.get(1) or 0)
        code, text, system = seg.get(3, 1), seg.get(3, 2), seg.get(3, 3)
        loinc = ref.to_loinc(facility, code, system, seg.get(3, 4), seg.get(3, 6))
        if not loinc:
            rejects.append(Reject(facility, ctl, set_id, UNMAPPED_CODE, f"{code}^{text}^{system}"))
            continue

        vtype = seg.get(2).upper()
        status = seg.get(11).upper() or "F"
        try:
            # X (cannot be obtained) / D (delete) carry no value by design.
            if status in ("X", "D"):
                comparator, num, vtext = "", None, ""
            else:
                comparator, num, vtext = parse_value(vtype, seg)
        except ValueError as exc:
            rejects.append(Reject(facility, ctl, set_id, NON_NUMERIC, str(exc)))
            continue

        src_unit = seg.get(6, 1)
        unit = src_unit
        if num is not None:
            converted = ref.convert(loinc, num, src_unit)
            if converted is None:
                rejects.append(Reject(facility, ctl, set_id, UNIT_NOT_CONVERTIBLE,
                                      f"LOINC {loinc} unit {src_unit!r}"))
                continue
            num, unit = converted

        # OBX-14 is the clinically relevant time; fall back to OBR-7 collection time.
        ts_raw = seg.get(14) or obr.get(7)
        try:
            observed = _iso(parse_hl7_ts(ts_raw, tz))
        except ValueError as exc:
            rejects.append(Reject(facility, ctl, set_id, BAD_TIMESTAMP, str(exc)))
            continue

        rows.append(Observation(
            sending_facility=facility, message_control_id=ctl, message_datetime_utc=msg_dt,
            mrn=mrn, mrn_assigning_authority=auth,
            accession_number=obr.get(3, 1) or obr.get(2, 1), order_code=obr.get(4, 1),
            obx_set_id=set_id, loinc=loinc, source_code=code, source_code_system=system,
            observation_text=text, value_type=vtype, comparator=comparator,
            value_numeric=num, value_text=vtext, unit=unit,
            source_value=seg.get(5) if vtype != "SN" else vtext, source_unit=src_unit,
            reference_range=seg.get(7), abnormal_flag=seg.get(8),
            result_status=status, observed_at_utc=observed,
        ))
    return rows, rejects
