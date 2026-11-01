from oru_feed.hl7 import Delimiters, parse_message, split_stream, unescape

STD = "MSH|^~\\&|LIS|LAB|RCV|HDE|202610290800||ORU^R01|CTL1|P|2.5.1"


def test_msh_field_numbering():
    msg = parse_message(STD)
    assert msg.msh.get(1) == "|"
    assert msg.msh.get(3) == "LIS"
    assert msg.msh.get(10) == "CTL1"
    assert msg.message_type == "ORU^R01"


def test_custom_component_delimiter():
    msg = parse_message("MSH|#~\\&|LIS|CEDAR|R|H|20261029||ORU#R01|C9|P|2.5.1\rPID|1||123###CEDAR#MR")
    assert msg.msh.get(4) == "CEDAR"
    assert msg.message_type == "ORU^R01"
    assert msg.first("PID").get(3, 5) == "MR"


def test_repetitions_and_components():
    msg = parse_message(STD + "\rPID|1||A1^^^X^MB~M77^^^HOSP^MR")
    pid = msg.first("PID")
    assert len(pid.repetitions(3)) == 2
    assert pid.get(3, 1, rep=2) == "M77"
    assert pid.get(3, 4, rep=2) == "HOSP"
    assert pid.get(99) == ""             # missing positions are blank, not errors


def test_escape_sequences():
    d = Delimiters()
    assert unescape("A \\T\\ B \\F\\ C \\S\\ D \\E\\", d) == "A & B | C ^ D \\"
    assert unescape("line1\\.br\\line2", d) == "line1\nline2"
    assert unescape("keep \\Z99\\ as is", d) == "keep \\Z99\\ as is"


def test_split_mllp_stream():
    blob = f"\x0b{STD}\rPID|1\r\x1c\r\x0b{STD.replace('CTL1', 'CTL2')}\r\x1c\r"
    msgs = [parse_message(t) for t in split_stream(blob)]
    assert [m.control_id for m in msgs] == ["CTL1", "CTL2"]
    assert msgs[0].segments[1].name == "PID"


def test_split_batch_file_drops_envelope():
    blob = "FHS|^~\\&\nBHS|^~\\&\n" + STD + "\nPID|1\n" + STD.replace("CTL1", "CTL2") + "\nBTS|2\nFTS|1\n"
    texts = list(split_stream(blob))
    assert len(texts) == 2
    assert all(t.startswith("MSH") for t in texts)
