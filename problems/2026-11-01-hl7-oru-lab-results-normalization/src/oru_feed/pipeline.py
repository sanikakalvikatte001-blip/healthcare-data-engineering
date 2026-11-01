"""Feed-level processing: dedupe resends, apply corrections, build ACKs, write outputs."""
from __future__ import annotations

import csv
import json
from collections import Counter
from dataclasses import asdict, dataclass, field, fields
from pathlib import Path

from .hl7 import HL7ParseError, Message, parse_message, split_stream
from .oru import Observation, Reject, map_oru
from .reference import ReferenceData

UNPARSEABLE = "UNPARSEABLE_MESSAGE"
TERMINAL_DELETE = {"X", "D"}   # OBX-11: cancelled / deleted -> remove from current state


@dataclass
class FeedResult:
    messages_read: int = 0
    duplicate_messages: int = 0
    observations_parsed: int = 0
    superseded: int = 0
    cancelled: int = 0
    current: list[Observation] = field(default_factory=list)
    rejects: list[Reject] = field(default_factory=list)
    acks: list[str] = field(default_factory=list)

    def summary(self) -> dict:
        by_reason = Counter(r.reason for r in self.rejects)
        return {
            "messages_read": self.messages_read,
            "duplicate_messages_skipped": self.duplicate_messages,
            "observations_parsed": self.observations_parsed,
            "observations_superseded": self.superseded,
            "observations_cancelled": self.cancelled,
            "observations_current": len(self.current),
            "rejects_total": len(self.rejects),
            "rejects_by_reason": dict(sorted(by_reason.items())),
            "acks_by_code": dict(sorted(Counter(a.split("MSA|")[1][:2] for a in self.acks).items())),
            "patients_with_results": len({(o.sending_facility, o.mrn) for o in self.current}),
        }


def build_ack(msg: Message | None, code: str, text: str, ack_ts: str) -> str:
    """HL7 ACK reply (AA accept, AE accepted with errors, AR rejected)."""
    if msg is None:
        return f"MSH|^~\\&|HDE_INGEST|HDE|||{ack_ts}||ACK|ACK_UNKNOWN|P|2.5.1\rMSA|AR||{text}"
    m = msg.msh
    return (f"MSH|^~\\&|HDE_INGEST|HDE|{m.get(3)}|{m.get(4)}|{ack_ts}||ACK^R01|"
            f"ACK{msg.control_id}|P|2.5.1\rMSA|{code}|{msg.control_id}|{text}")


def resolve_current_state(rows: list[Observation]) -> tuple[list[Observation], int, int]:
    """Collapse result versions to the latest one per result key.

    Key = (facility, accession, LOINC). Later messages win (P -> F -> C);
    a final X/D status removes the result entirely.
    Returns (current rows, superseded count, cancelled count).
    """
    latest: dict[tuple[str, str, str], Observation] = {}
    superseded = 0
    # stable sort keeps file order for ties on message time
    for row in sorted(rows, key=lambda r: r.message_datetime_utc):
        key = (row.sending_facility, row.accession_number, row.loinc)
        if key in latest:
            superseded += 1
        latest[key] = row
    current = [r for r in latest.values() if r.result_status not in TERMINAL_DELETE]
    cancelled = len(latest) - len(current)
    current.sort(key=lambda r: (r.sending_facility, r.mrn, r.observed_at_utc, r.loinc))
    return current, superseded, cancelled


def process_feed(texts: list[str], ref: ReferenceData, ack_ts: str = "20261101000000") -> FeedResult:
    res = FeedResult()
    seen: set[tuple[str, str]] = set()
    parsed: list[Observation] = []

    for text in texts:
        res.messages_read += 1
        try:
            msg = parse_message(text)
        except HL7ParseError as exc:
            res.rejects.append(Reject("", "", None, UNPARSEABLE, str(exc)))
            res.acks.append(build_ack(None, "AR", str(exc), ack_ts))
            continue

        key = (msg.msh.get(4) or msg.msh.get(3), msg.control_id)
        if key in seen:
            # Same MSH-10 resent (interface engine retry): ACK it, load nothing.
            res.duplicate_messages += 1
            res.acks.append(build_ack(msg, "AA", "duplicate control id - already processed", ack_ts))
            continue
        seen.add(key)

        rows, rejects = map_oru(msg, ref)
        parsed.extend(rows)
        res.rejects.extend(rejects)
        if rejects and not rows:
            code = "AR"
        elif rejects:
            code = "AE"
        else:
            code = "AA"
        detail = "; ".join(sorted({r.reason for r in rejects})) or "OK"
        res.acks.append(build_ack(msg, code, detail, ack_ts))

    res.observations_parsed = len(parsed)
    res.current, res.superseded, res.cancelled = resolve_current_state(parsed)
    return res


def read_feed_dir(input_dir: str | Path) -> list[str]:
    """All messages from *.hl7 files in name order (deterministic replay)."""
    texts: list[str] = []
    for path in sorted(Path(input_dir).glob("*.hl7")):
        texts.extend(split_stream(path.read_text(encoding="utf-8")))
    return texts


def _write_csv(path: Path, rows: list, cls) -> None:
    cols = [f.name for f in fields(cls)]
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow(asdict(r))


def write_outputs(res: FeedResult, out_dir: str | Path) -> dict:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    _write_csv(out / "observations.csv", res.current, Observation)
    _write_csv(out / "rejects.csv", res.rejects, Reject)
    # One ACK per line, segments joined with CR as on the wire
    (out / "acks.hl7").write_text("\n".join(res.acks) + "\n", encoding="utf-8")
    summary = res.summary()
    (out / "run_summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary
