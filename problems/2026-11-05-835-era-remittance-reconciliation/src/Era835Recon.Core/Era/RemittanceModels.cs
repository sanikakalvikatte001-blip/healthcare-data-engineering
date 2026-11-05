namespace Era835Recon.Core.Era;

/// <summary>
/// CAS adjustment. Group codes: CO (contractual), PR (patient responsibility),
/// OA (other), PI (payer initiated), CR (correction/reversal).
/// Reason codes are CARCs, e.g. 45 = charge exceeds fee schedule, 1 = deductible, 2 = coinsurance.
/// </summary>
public sealed record Adjustment(string GroupCode, string ReasonCode, decimal Amount);

/// <summary>SVC loop (2110): one paid service line with its line-level adjustments.</summary>
public sealed class ServiceLinePayment
{
    public required string ProcedureCode { get; init; }      // SVC01-2 (CPT/HCPCS)
    public required decimal ChargeAmount { get; init; }      // SVC02
    public required decimal PaidAmount { get; init; }        // SVC03
    public decimal Units { get; init; } = 1;                  // SVC05
    public DateOnly? ServiceDate { get; set; }                // DTM*472
    public List<Adjustment> Adjustments { get; } = new();

    public decimal AdjustmentTotal => Adjustments.Sum(a => a.Amount);
}

/// <summary>CLP loop (2100): one adjudicated claim inside an 835.</summary>
public sealed class ClaimPayment
{
    public required string PatientControlNumber { get; init; } // CLP01 = our 837 CLM01
    public required string StatusCode { get; init; }           // CLP02: 1/2/3 processed, 4 denied, 22 reversal
    public required decimal ChargeAmount { get; init; }        // CLP03
    public required decimal PaidAmount { get; init; }          // CLP04
    public decimal PatientResponsibility { get; init; }        // CLP05
    public string PayerClaimControlNumber { get; init; } = ""; // CLP07 (payer ICN)
    public string PatientMemberId { get; set; } = "";          // NM1*QC NM109
    public DateOnly? StatementFromDate { get; set; }           // DTM*232
    public List<Adjustment> Adjustments { get; } = new();      // claim-level CAS
    public List<ServiceLinePayment> ServiceLines { get; } = new();

    /// <summary>Owning remittance's check/EFT trace number (TRN02), set by the parser.</summary>
    public string TraceNumber { get; set; } = "";
    public string PayerId { get; set; } = "";

    public bool IsReversal => StatusCode == "22";
    public bool IsDenied => StatusCode == "4";

    /// <summary>All adjustments: claim-level plus every service line.</summary>
    public IEnumerable<Adjustment> AllAdjustments =>
        Adjustments.Concat(ServiceLines.SelectMany(l => l.Adjustments));
}

/// <summary>PLB: provider-level adjustment (interest, recoupment, ...). Positive reduces the payment.</summary>
public sealed record ProviderAdjustment(string ReasonCode, string Reference, decimal Amount);

/// <summary>One 835 transaction set (ST..SE): a single check or EFT to a single payee.</summary>
public sealed class Remittance
{
    public required string SourceFile { get; init; }
    public string TraceNumber { get; set; } = "";        // TRN02 check/EFT number
    public decimal TotalPaymentAmount { get; set; }       // BPR02
    public string PaymentMethod { get; set; } = "";       // BPR04 (ACH, CHK, NON)
    public DateOnly? PaymentDate { get; set; }            // BPR16
    public string PayerName { get; set; } = "";           // N1*PR
    public string PayerId { get; set; } = "";             // N1*PR N104 (or REF*2U)
    public string PayeeName { get; set; } = "";           // N1*PE
    public string PayeeNpi { get; set; } = "";            // N1*PE N104 when N103 = XX
    public List<ClaimPayment> Claims { get; } = new();
    public List<ProviderAdjustment> ProviderAdjustments { get; } = new();
}
