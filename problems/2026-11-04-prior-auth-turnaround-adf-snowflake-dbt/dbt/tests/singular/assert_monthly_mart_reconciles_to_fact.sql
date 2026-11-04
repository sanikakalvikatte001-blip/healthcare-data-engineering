-- Determinations in the monthly mart must add back to the fact table,
-- overall and by status.
with fact as (
    select count(*) as determinations,
           sum(case when determination_status = 'DENIED' then 1 else 0 end) as denied,
           sum(case when met_timeframe then 0 else 1 end) as late
    from {{ ref('fct_prior_auth_request') }}
    where lifecycle_status = 'DETERMINED'
),
mart as (
    select sum(determinations) as determinations,
           sum(round(determinations * pct_denied / 100.0)) as denied,
           sum(late_determinations) as late
    from {{ ref('mart_pa_turnaround_monthly') }}
)
select *
from fact, mart
where fact.determinations <> mart.determinations
   or fact.late <> mart.late
   or abs(fact.denied - mart.denied) > 0
