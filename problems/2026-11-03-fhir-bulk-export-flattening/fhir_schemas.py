"""
Explicit Spark schemas (DDL strings) for the FHIR R4 resources we flatten.

Why explicit schemas instead of letting Spark infer them:
  * inference scans every file twice and the result changes from export to export
    (a choice type such as valueString only appears if some row happens to use it);
  * a fixed schema is a contract - the SQL downstream can rely on every column existing;
  * fields we do not model are simply ignored, so new FHIR extensions do not break the load.

Only the elements the warehouse needs are declared. `_corrupt_record` captures any
line that is not valid JSON so it can be quarantined instead of failing the job.
"""

CODING = "ARRAY<STRUCT<system: STRING, code: STRING, display: STRING>>"
CODEABLE = f"STRUCT<coding: {CODING}, text: STRING>"
QUANTITY = "STRUCT<value: DOUBLE, unit: STRING, system: STRING, code: STRING>"
REFERENCE = "STRUCT<reference: STRING, display: STRING>"
META = "STRUCT<versionId: STRING, lastUpdated: STRING>"
CORRUPT = "_corrupt_record STRING"

PATIENT = f"""
    resourceType STRING,
    id STRING,
    meta {META},
    extension ARRAY<STRUCT<url: STRING, valueCode: STRING>>,
    identifier ARRAY<STRUCT<`type`: {CODEABLE}, system: STRING, value: STRING>>,
    name ARRAY<STRUCT<use: STRING, family: STRING, given: ARRAY<STRING>>>,
    gender STRING,
    birthDate STRING,
    telecom ARRAY<STRUCT<system: STRING, value: STRING, use: STRING>>,
    address ARRAY<STRUCT<use: STRING, state: STRING, postalCode: STRING>>,
    deceasedBoolean BOOLEAN,
    {CORRUPT}
"""

ENCOUNTER = f"""
    resourceType STRING,
    id STRING,
    meta {META},
    status STRING,
    `class` STRUCT<system: STRING, code: STRING>,
    `type` ARRAY<{CODEABLE}>,
    subject {REFERENCE},
    period STRUCT<start: STRING, `end`: STRING>,
    {CORRUPT}
"""

# value[x] is a FHIR "choice type": exactly one of valueQuantity / valueCodeableConcept /
# valueString (or dataAbsentReason) is present. Each choice gets its own struct column.
_VALUE_X = f"""
    valueQuantity {QUANTITY},
    valueCodeableConcept {CODEABLE},
    valueString STRING
"""

OBSERVATION = f"""
    resourceType STRING,
    id STRING,
    meta {META},
    status STRING,
    category ARRAY<{CODEABLE}>,
    code {CODEABLE},
    subject {REFERENCE},
    encounter {REFERENCE},
    effectiveDateTime STRING,
    {_VALUE_X},
    dataAbsentReason {CODEABLE},
    component ARRAY<STRUCT<code: {CODEABLE}, {_VALUE_X}>>,
    {CORRUPT}
"""

# resource type -> (schema DDL, raw view name the SQL layer reads from)
RESOURCES = {
    "Patient": (PATIENT, "raw_patient"),
    "Encounter": (ENCOUNTER, "raw_encounter"),
    "Observation": (OBSERVATION, "raw_observation"),
}
