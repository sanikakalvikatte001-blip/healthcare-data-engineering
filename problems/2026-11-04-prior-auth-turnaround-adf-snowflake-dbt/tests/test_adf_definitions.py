"""Static checks for the ADF git-mode definitions in adf/.

ADF isn't available in CI, so these catch the mistakes that usually break a
publish: dangling references, missing dataset parameters, bad dependsOn
names, and unbalanced expressions.
"""
import json
import re
from pathlib import Path

import pytest

ADF = Path(__file__).resolve().parents[1] / "adf"
FILES = sorted(ADF.rglob("*.json"))
DEFS = {p.stem: json.loads(p.read_text()) for p in FILES}
KIND_DIR = {"LinkedServiceReference": "linkedService", "DatasetReference": "dataset",
            "PipelineReference": "pipeline"}


def walk(node):
    """Yield every dict nested anywhere in node."""
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)


def activities(acts):
    for a in acts:
        yield a
        yield from activities(a.get("typeProperties", {}).get("activities", []))


@pytest.mark.parametrize("path", FILES, ids=lambda p: p.stem)
def test_name_matches_file(path):
    assert DEFS[path.stem]["name"] == path.stem


@pytest.mark.parametrize("path", FILES, ids=lambda p: p.stem)
def test_references_resolve(path):
    for d in walk(DEFS[path.stem]):
        if d.get("type") in KIND_DIR and "referenceName" in d:
            target = ADF / KIND_DIR[d["type"]] / f"{d['referenceName']}.json"
            assert target.exists(), f"{path.stem}: missing {target.relative_to(ADF)}"


def test_dataset_parameters_supplied():
    pipe = DEFS["pl_um_incremental_to_snowflake"]["properties"]
    for act in activities(pipe["activities"]):
        for ref in act.get("inputs", []) + act.get("outputs", []):
            declared = set(DEFS[ref["referenceName"]]["properties"].get("parameters", {}))
            assert declared == set(ref.get("parameters", {})), act["name"]


def test_depends_on_siblings():
    def check(acts):
        names = {a["name"] for a in acts}
        for a in acts:
            for dep in a.get("dependsOn", []):
                assert dep["activity"] in names, f"{a['name']} -> {dep['activity']}"
            check(a.get("typeProperties", {}).get("activities", []))
    check(DEFS["pl_um_incremental_to_snowflake"]["properties"]["activities"])


def balanced(expr: str) -> bool:
    """Parentheses balance outside ADF string literals ('' escapes a quote)."""
    depth, in_str, i = 0, False, 0
    while i < len(expr):
        c = expr[i]
        if c == "'":
            if in_str and i + 1 < len(expr) and expr[i + 1] == "'":
                i += 2
                continue
            in_str = not in_str
        elif not in_str:
            depth += {"(": 1, ")": -1}.get(c, 0)
            if depth < 0:
                return False
        i += 1
    return depth == 0 and not in_str


def test_expressions_balanced():
    exprs = [d["value"] for f in DEFS.values() for d in walk(f)
             if d.get("type") == "Expression" and isinstance(d.get("value"), str)]
    assert exprs, "expected dynamic expressions in the pipeline"
    bad = [e for e in exprs if e.startswith("@") and not balanced(e[1:])]
    assert not bad, bad


def test_copy_select_matches_raw_table_columns():
    """Each COPY select list must cover every RAW column except the 2 metadata columns."""
    ddl = (ADF.parent / "snowflake" / "02_raw_and_control_tables.sql").read_text()
    tables = DEFS["pl_um_incremental_to_snowflake"]["properties"]["parameters"]["tables"]["defaultValue"]
    for t in tables:
        name = t["rawTable"].split(".")[-1]
        body = re.search(rf"CREATE TABLE IF NOT EXISTS RAW\.UM\.{name} \((.*?)\n\);", ddl, re.S).group(1)
        raw_cols = [ln.split()[0].lower() for ln in body.strip().splitlines() if ln.strip()]
        selected = re.findall(r"\$1:(\w+)::", t["copySelect"])
        assert selected + ["_file_name", "_loaded_at"] == raw_cols, name
