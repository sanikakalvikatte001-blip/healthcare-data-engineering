namespace CcdaIngest.Synthetic;

/// <summary>
/// Two daily drops from a (fictional) HIE feed, built to contain every case the ingestion must handle.
/// All names, MRNs and OIDs are invented. Codes are public SNOMED CT / RxNorm / LOINC concepts.
///
///   batch1 (2026-11-10)                         batch2 (2026-11-11)
///   01 Ava  CCD setA v1          -> Loaded      01 Ava  CCD v1, re-serialized   -> DuplicateContent
///   02 Ava  CCD setA v1 (copy)   -> DupFile     02 Marcus CCD v1 (copy again)   -> DuplicateFile
///   03 Marcus CCD setB v1        -> Loaded      03 Marcus CCD setB v2 (RPLC)    -> Loaded, v1 Superseded
///   04 Priya CCD setC v2         -> Loaded      04 Priya CCD setC v1 (late)     -> StaleVersion
///   05 Gerald CCD setD v1        -> Loaded      05 Ava  encounter summary setE  -> Loaded (overlaps setA)
///   06 truncated XML             -> Rejected    06 Gerald, reused document id   -> RejectedIdConflict
///                                               07 no patient identifier        -> RejectedInvalid
/// </summary>
public static class SyntheticFeed
{
    private static readonly PatientSpec Ava = new("100001", "Ava", "Thornton", "19580314", "F");
    private static readonly PatientSpec Marcus = new("100002", "Marcus", "Delgado", "19621102", "M");
    private static readonly PatientSpec Priya = new("100003", "Priya", "Raman", "19750721", "F");
    private static readonly PatientSpec Gerald = new("100004", "Gerald", "Okafor", "19490130", "M");

    // Reusable coded concepts
    private static CodedItem Diabetes(string id, string status = "active") => new(id, "44054006", "Diabetes mellitus type 2", status, "20190415");
    private static CodedItem Hypertension(string id) => new(id, "38341003", "Hypertensive disorder", "active", "20170902");
    private static CodedItem Hyperlipidemia(string id, string start) => new(id, "55822004", "Hyperlipidemia", "active", start);

    public static DocumentSpec AvaCcd => new("CCD-A-0001", "SET-A", 1, null, "20261103091500-0500", Ava, "Continuity of Care Document",
        Problems: [Diabetes("A-P1"), Hypertension("A-P2")],
        Medications: [new("A-M1", "861007", "metformin hydrochloride 500 MG Oral Tablet", "active", "20240210"),
                      new("A-M2", "314076", "lisinopril 10 MG Oral Tablet", "active", "20230601")],
        Allergies: [new("A-L1", "7980", "Penicillin G", "active", "20000101")],
        Results: [new("A-R1", "4548-4", "Hemoglobin A1c/Hemoglobin.total in Blood", "20261028", "7.4", "%"),
                  new("A-R2", "13457-7", "Cholesterol in LDL [Mass/volume] in Serum or Plasma by calculation", "20261028", "118", "mg/dL")]);

    public static DocumentSpec MarcusCcdV1 => new("CCD-B-0001", "SET-B", 1, null, "20261104141000-0500", Marcus, "Continuity of Care Document",
        Problems: [Hyperlipidemia("B-P1", "20210311"),
                   new("B-P2", "195967001", "Asthma", "active", "19980101"),
                   new("B-P3", "", "Unmapped local problem: 'back pain - chronic?'", "active", "20250601")], // nullFlavor code
        Medications: [new("B-M1", "617310", "atorvastatin 20 MG Oral Tablet", "active", "20210320"),
                      new("B-M2", "745679", "albuterol 0.09 MG/ACTUAT Metered Dose Inhaler", "active", "20200115")],
        Allergies: [new("B-L1", "2670", "Codeine", "active", "20150101")],
        Results: [new("B-R1", "13457-7", "Cholesterol in LDL [Mass/volume] in Serum or Plasma by calculation", "20261030", "162", "mg/dL")]);

    // Replacement (RPLC) of Marcus v1: asthma resolved, albuterol stopped, unmapped problem dropped, new LDL.
    public static DocumentSpec MarcusCcdV2 => MarcusCcdV1 with
    {
        DocumentIdExt = "CCD-B-0002", Version = 2, ReplacesIdExt = "CCD-B-0001", EffectiveTime = "20261110103000-0500",
        Problems = [Hyperlipidemia("B-P1", "20210311"), new("B-P2", "195967001", "Asthma", "completed", "19980101", "20261108")],
        Medications = [new("B-M1", "617310", "atorvastatin 20 MG Oral Tablet", "active", "20210320"),
                       new("B-M2", "745679", "albuterol 0.09 MG/ACTUAT Metered Dose Inhaler", "completed", "20200115", "20261108")],
        Results = [new("B-R1", "13457-7", "Cholesterol in LDL [Mass/volume] in Serum or Plasma by calculation", "20261030", "162", "mg/dL"),
                   new("B-R2", "13457-7", "Cholesterol in LDL [Mass/volume] in Serum or Plasma by calculation", "20261109", "131", "mg/dL")],
    };

    public static DocumentSpec PriyaCcdV2 => new("CCD-C-0002", "SET-C", 2, "CCD-C-0001", "20261106080000-0500", Priya, "Continuity of Care Document",
        Problems: [Hypertension("C-P1"), new("C-P2", "433144002", "Chronic kidney disease stage 3", "active", "20250115")],
        Medications: [new("C-M1", "197361", "amlodipine 5 MG Oral Tablet", "active", "20220505")],
        Allergies: [new("C-L1", "10831", "Sulfamethoxazole", "active", "20100101")],
        Results: [new("C-R1", "33914-3", "Glomerular filtration rate/1.73 sq M.predicted", "20261101", "52", "mL/min/{1.73_m2}"),
                  new("C-R2", "2160-0", "Creatinine [Mass/volume] in Serum or Plasma", "20261101", "1.3", "mg/dL")]);

    // The older version arrives a week late (e.g. an interface engine replaying its queue).
    public static DocumentSpec PriyaCcdV1 => PriyaCcdV2 with
    {
        DocumentIdExt = "CCD-C-0001", Version = 1, ReplacesIdExt = null, EffectiveTime = "20261020080000-0500",
        Problems = [Hypertension("C-P1")], Results = [],
    };

    public static DocumentSpec GeraldCcd => new("CCD-D-0001", "SET-D", 1, null, "20261105160000-0500", Gerald, "Continuity of Care Document",
        Problems: [new("D-P1", "13645005", "Chronic obstructive lung disease", "active", "20160810")],
        Medications: [new("D-M1", "745679", "albuterol 0.09 MG/ACTUAT Metered Dose Inhaler", "active", "20160815")],
        Allergies: [new("D-L1", "1191", "Aspirin", "active", "19900101")],
        Results: [new("D-R1", "2345-7", "Glucose [Mass/volume] in Serum or Plasma", "20261102", "104", "mg/dL")]);

    // Source system reused the document id for different content (an id-generation bug upstream).
    public static DocumentSpec GeraldIdConflict => GeraldCcd with
    {
        EffectiveTime = "20261111090000-0500",
        Results = [new("D-R1", "2345-7", "Glucose [Mass/volume] in Serum or Plasma", "20261102", "99", "mg/dL")],
    };

    // A second, different document for Ava (encounter summary) - overlaps her CCD's problems, meds and results.
    public static DocumentSpec AvaEncounter => new("ENC-A-0001", "SET-E", 1, null, "20261111113000-0500", Ava, "Encounter Summary",
        Problems: [Diabetes("E-P1"), Hypertension("E-P2"), Hyperlipidemia("E-P3", "20261111")],
        Medications: [new("E-M1", "861007", "metformin hydrochloride 500 MG Oral Tablet", "active", "20240210"),
                      new("E-M2", "314076", "lisinopril 10 MG Oral Tablet", "completed", "20230601", "20261111"),
                      new("E-M3", "197361", "amlodipine 5 MG Oral Tablet", "active", "20261111")],
        Allergies: [new("E-L1", "7980", "Penicillin G", "active", "20000101")],
        Results: [new("E-R1", "4548-4", "Hemoglobin A1c/Hemoglobin.total in Blood", "20261028", "7.4", "%"),
                  new("E-R2", "4548-4", "Hemoglobin A1c/Hemoglobin.total in Blood", "20261110", "6.9", "%")]);

    public static DocumentSpec MissingPatientId => new("CCD-X-0001", "SET-X", 1, null, "20261111150000-0500", null, "Continuity of Care Document",
        Problems: [], Medications: [], Allergies: [], Results: []);

    /// <summary>Returns batch name -> (file name, bytes). Deterministic: same input, same bytes, same hashes.</summary>
    public static Dictionary<string, List<(string FileName, byte[] Bytes)>> Build()
    {
        var avaBytes = CcdaBuilder.Serialize(CcdaBuilder.Build(AvaCcd));
        var marcusV1Bytes = CcdaBuilder.Serialize(CcdaBuilder.Build(MarcusCcdV1));
        var geraldBytes = CcdaBuilder.Serialize(CcdaBuilder.Build(GeraldCcd));

        return new()
        {
            ["batch1"] =
            [
                ("01_ccd_100001.xml", avaBytes),
                ("02_ccd_100001_retry.xml", avaBytes.ToArray()),
                ("03_ccd_100002.xml", marcusV1Bytes),
                ("04_ccd_100003_v2.xml", CcdaBuilder.Serialize(CcdaBuilder.Build(PriyaCcdV2))),
                ("05_ccd_100004.xml", geraldBytes),
                ("06_ccd_truncated.xml", geraldBytes[..(geraldBytes.Length / 2)]), // transfer cut off mid-file
            ],
            ["batch2"] =
            [
                ("01_ccd_100001_gateway.xml", CcdaBuilder.SerializeAsOtherSystem(CcdaBuilder.Build(AvaCcd))),
                ("02_ccd_100002_resend.xml", marcusV1Bytes.ToArray()),
                ("03_ccd_100002_v2.xml", CcdaBuilder.Serialize(CcdaBuilder.Build(MarcusCcdV2))),
                ("04_ccd_100003_v1_late.xml", CcdaBuilder.Serialize(CcdaBuilder.Build(PriyaCcdV1))),
                ("05_enc_100001.xml", CcdaBuilder.Serialize(CcdaBuilder.Build(AvaEncounter))),
                ("06_ccd_100004_reissued.xml", CcdaBuilder.Serialize(CcdaBuilder.Build(GeraldIdConflict))),
                ("07_ccd_no_patient_id.xml", CcdaBuilder.Serialize(CcdaBuilder.Build(MissingPatientId))),
            ],
        };
    }

    public static void WriteTo(string inboxRoot)
    {
        foreach (var (batch, files) in Build())
        {
            var dir = Path.Combine(inboxRoot, batch);
            Directory.CreateDirectory(dir);
            foreach (var (name, bytes) in files) File.WriteAllBytes(Path.Combine(dir, name), bytes);
        }
    }
}
