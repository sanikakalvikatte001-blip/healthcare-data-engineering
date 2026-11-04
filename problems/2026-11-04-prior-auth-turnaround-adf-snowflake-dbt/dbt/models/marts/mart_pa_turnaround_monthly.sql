-- Monthly determination metrics in the shape of the CMS-0057-F public
-- reporting items: % approved / denied, average and median time from
-- receipt to determination, split by priority (expedited vs standard).
-- Grain: determination_month x line_of_business x priority.
with determined as (
    select *
    from {{ ref('fct_prior_auth_request') }}
    where lifecycle_status = 'DETERMINED'
)

select
    determination_month,
    line_of_business,
    priority,
    count(*)                                                                  as determinations,
    round(100.0 * avg(case when determination_status = 'APPROVED' then 1.0 else 0 end), 1)
                                                                              as pct_approved,
    round(100.0 * avg(case when determination_status = 'PARTIAL_APPROVED' then 1.0 else 0 end), 1)
                                                                              as pct_partial,
    round(100.0 * avg(case when determination_status = 'DENIED' then 1.0 else 0 end), 1)
                                                                              as pct_denied,
    round(avg(turnaround_hours), 1)                                           as avg_turnaround_hours,
    round(median(turnaround_hours), 1)                                        as median_turnaround_hours,
    round(percentile_cont(0.9) within group (order by turnaround_hours), 1)   as p90_turnaround_hours,
    max(timeframe_hours)                                                      as timeframe_hours,
    round(100.0 * avg(case when met_timeframe then 1.0 else 0 end), 1)        as pct_within_timeframe,
    sum(case when met_timeframe then 0 else 1 end)                            as late_determinations
from determined
group by determination_month, line_of_business, priority
