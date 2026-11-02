-- =============================================================================
-- V002  Matching configuration (data, not code)
--
-- Weights follow the Fellegi-Sunter idea: each field outcome adds roughly
-- log2(m/u) - how much more likely that outcome is for a true match than for
-- a non-match. Strong identifiers (SSN, DOB) carry big weights; weak ones
-- (sex, ZIP) carry small ones. Stewards tune these rows, not the procedure.
-- =============================================================================

CREATE TABLE mpi.match_weight (
    field    text NOT NULL,
    outcome  text NOT NULL CHECK (outcome IN ('AGREE', 'PARTIAL', 'DISAGREE', 'MISSING')),
    weight   numeric(5,2) NOT NULL,
    PRIMARY KEY (field, outcome)
);

INSERT INTO mpi.match_weight (field, outcome, weight) VALUES
    -- last name: disagreement is mild because people change surnames
    ('last',  'AGREE',  4.0), ('last',  'PARTIAL', 2.0), ('last',  'DISAGREE', -2.0), ('last',  'MISSING', 0),
    -- first name (after nickname resolution): a different first name is strong evidence of a different person (twins)
    ('first', 'AGREE',  3.5), ('first', 'PARTIAL', 1.5), ('first', 'DISAGREE', -4.0), ('first', 'MISSING', 0),
    -- date of birth: PARTIAL = day/month swapped or exactly one component off
    ('dob',   'AGREE',  5.0), ('dob',   'PARTIAL', 2.0), ('dob',   'DISAGREE', -4.0), ('dob',   'MISSING', 0),
    -- SSN: decisive when both sides have one. One digit apart is NOT evidence
    -- either way: it is a typo or, just as often, twins with consecutive SSNs.
    ('ssn',   'AGREE',  8.0), ('ssn',   'PARTIAL', 0.0), ('ssn',   'DISAGREE', -8.0), ('ssn',   'MISSING', 0),
    ('sex',   'AGREE',  0.5), ('sex',   'PARTIAL', 0),   ('sex',   'DISAGREE', -2.0), ('sex',   'MISSING', 0),
    ('phone', 'AGREE',  2.5), ('phone', 'PARTIAL', 0),   ('phone', 'DISAGREE', -0.5), ('phone', 'MISSING', 0),
    ('zip',   'AGREE',  1.0), ('zip',   'PARTIAL', 0),   ('zip',   'DISAGREE', -0.5), ('zip',   'MISSING', 0),
    ('addr',  'AGREE',  2.0), ('addr',  'PARTIAL', 1.0), ('addr',  'DISAGREE', -0.5), ('addr',  'MISSING', 0);

CREATE TABLE mpi.match_threshold (
    name   text PRIMARY KEY,
    value  numeric(5,2) NOT NULL
);
INSERT INTO mpi.match_threshold VALUES
    ('AUTO_LINK', 12.0),   -- >= 12   : link automatically
    ('REVIEW',     7.0);   -- 7 - 12  : send to a data steward; < 7 : different people

-- Nickname -> canonical given name. Small on purpose; production MPIs load a
-- few thousand rows from a licensed or curated list.
CREATE TABLE mpi.nickname (
    nickname   text PRIMARY KEY,
    canonical  text NOT NULL
);
INSERT INTO mpi.nickname VALUES
    ('BOB','ROBERT'), ('BOBBY','ROBERT'), ('ROB','ROBERT'), ('BILL','WILLIAM'), ('BILLY','WILLIAM'),
    ('WILL','WILLIAM'), ('LIZ','ELIZABETH'), ('BETH','ELIZABETH'), ('BETTY','ELIZABETH'),
    ('JIM','JAMES'), ('JIMMY','JAMES'), ('MIKE','MICHAEL'), ('KATE','KATHERINE'), ('KATHY','KATHERINE'),
    ('PEGGY','MARGARET'), ('MAGGIE','MARGARET'), ('TOM','THOMAS'), ('TONY','ANTHONY'),
    ('DICK','RICHARD'), ('RICK','RICHARD'), ('JOE','JOSEPH'), ('DAN','DANIEL'), ('DANNY','DANIEL'),
    ('CHRIS','CHRISTOPHER'), ('PATTY','PATRICIA'), ('TRISH','PATRICIA'), ('JENNY','JENNIFER'),
    ('JEN','JENNIFER'), ('SUE','SUSAN'), ('DAVE','DAVID'), ('STEVE','STEVEN'), ('ED','EDWARD'),
    ('TED','EDWARD'), ('ABBY','ABIGAIL'), ('SAM','SAMUEL'), ('MATT','MATTHEW'), ('NICK','NICHOLAS');
