"""Minimal, dependency-free HL7 v2 reader.

Handles the parts of HL7 v2 that break naive ``line.split('|')`` parsers:

* MLLP framing (``0x0B ... 0x1C 0x0D``) and batch files with mixed line endings
* per-message delimiters declared in MSH-1 / MSH-2 (labs do not all use ``|^~\\&``)
* field repetitions, components, sub-components
* escape sequences (\\F\\ \\S\\ \\T\\ \\R\\ \\E\\ and \\.br\\)

The model is intentionally small: a ``Message`` is a list of ``Segment``s and
fields are addressed with HL7-style 1-based positions, e.g. ``seg.get(3, 1)``
for PID-3.1.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Iterator

MLLP_START = "\x0b"
MLLP_END = "\x1c"


class HL7ParseError(ValueError):
    """Raised when a message is structurally unreadable (no usable MSH)."""


@dataclass(frozen=True)
class Delimiters:
    field: str = "|"
    component: str = "^"
    repetition: str = "~"
    escape: str = "\\"
    subcomponent: str = "&"

    @classmethod
    def from_msh(cls, msh_line: str) -> "Delimiters":
        # MSH-1 is the character right after "MSH"; MSH-2 holds the other four.
        if len(msh_line) < 8 or not msh_line.startswith("MSH"):
            raise HL7ParseError("message does not start with a valid MSH segment")
        fsep = msh_line[3]
        enc = msh_line[4:].split(fsep, 1)[0]
        if len(enc) < 4:
            raise HL7ParseError(f"MSH-2 encoding characters incomplete: {enc!r}")
        return cls(fsep, enc[0], enc[1], enc[2], enc[3])


def unescape(value: str, d: Delimiters) -> str:
    """Decode HL7 escape sequences inside an already-split leaf value."""
    if d.escape not in value:
        return value
    e = re.escape(d.escape)
    table = {
        "F": d.field, "S": d.component, "T": d.subcomponent,
        "R": d.repetition, "E": d.escape, ".br": "\n",
    }

    def _sub(m: re.Match) -> str:
        return table.get(m.group(1), m.group(0))  # leave unknown escapes as-is

    return re.sub(f"{e}(F|S|T|R|E|\\.br){e}", _sub, value)


@dataclass
class Segment:
    name: str
    fields: list[str]          # raw (still escaped) field strings; index 0 = segment name
    delims: Delimiters

    def raw(self, pos: int) -> str:
        """Raw field text at HL7 position ``pos`` (MSH numbering handled)."""
        idx = pos - 1 if self.name == "MSH" else pos
        if self.name == "MSH" and pos == 1:
            return self.delims.field
        return self.fields[idx] if 0 <= idx < len(self.fields) else ""

    def repetitions(self, pos: int) -> list[str]:
        raw = self.raw(pos)
        if self.name == "MSH" and pos == 2:
            return [raw]
        return raw.split(self.delims.repetition) if raw else []

    def get(self, pos: int, comp: int = 1, sub: int = 1, rep: int = 1) -> str:
        """Return an unescaped leaf value; missing positions return ''."""
        reps = self.repetitions(pos)
        if len(reps) < rep:
            return ""
        comps = reps[rep - 1].split(self.delims.component)
        if len(comps) < comp:
            return ""
        subs = comps[comp - 1].split(self.delims.subcomponent)
        if len(subs) < sub:
            return ""
        return unescape(subs[sub - 1], self.delims).strip()

    def components(self, pos: int, rep: int = 1) -> list[str]:
        reps = self.repetitions(pos)
        if len(reps) < rep:
            return []
        return [unescape(c, self.delims).strip()
                for c in reps[rep - 1].split(self.delims.component)]


@dataclass
class Message:
    segments: list[Segment] = field(default_factory=list)
    raw_text: str = ""

    @property
    def msh(self) -> Segment:
        return self.segments[0]

    @property
    def message_type(self) -> str:
        return f"{self.msh.get(9, 1)}^{self.msh.get(9, 2)}"

    @property
    def control_id(self) -> str:
        return self.msh.get(10)

    def all(self, name: str) -> list[Segment]:
        return [s for s in self.segments if s.name == name]

    def first(self, name: str) -> Segment | None:
        return next((s for s in self.segments if s.name == name), None)


def parse_message(text: str) -> Message:
    """Parse one HL7 message (segments separated by CR, LF or CRLF)."""
    lines = [ln for ln in re.split(r"\r\n|\r|\n", text.strip()) if ln.strip()]
    if not lines:
        raise HL7ParseError("empty message")
    d = Delimiters.from_msh(lines[0])
    segs = []
    for ln in lines:
        parts = ln.split(d.field)
        segs.append(Segment(parts[0], parts, d))
    return Message(segs, text)


def split_stream(blob: str) -> Iterator[str]:
    """Split a feed file into individual message texts.

    Works for MLLP-framed captures and for plain batch files where each
    message starts with ``MSH``. FHS/BHS/BTS/FTS batch envelopes are dropped.
    """
    if MLLP_START in blob:
        for chunk in blob.split(MLLP_START):
            chunk = chunk.split(MLLP_END, 1)[0]
            if chunk.strip():
                yield chunk.strip()
        return
    current: list[str] = []
    for ln in re.split(r"\r\n|\r|\n", blob):
        if ln[:3] in ("FHS", "BHS", "BTS", "FTS"):
            continue
        if ln.startswith("MSH") and current:
            yield "\r".join(current)
            current = []
        if ln.strip():
            current.append(ln)
    if current:
        yield "\r".join(current)
