-- Work queue for the UM team: requests with no determination yet, aged
-- against the as-of timestamp. A view, so aging is always computed at
-- query time and never goes stale inside the incremental fact.
{{ config(materialized = 'view') }}

with open_requests as (
    select *
    from {{ ref('fct_prior_auth_request') }}
    where lifecycle_status = 'OPEN'
),

aged as (
    select
        request_id,
        line_of_business,
        service_category,
        priority,
        received_at,
        pend_count,
        timeframe_hours,
        {{ hours_between('received_at', as_of_ts()) }}               as age_hours
    from open_requests
)

select
    request_id,
    line_of_business,
    service_category,
    priority,
    received_at,
    pend_count,
    timeframe_hours,
    round(age_hours, 1)                                              as age_hours,
    round(timeframe_hours - age_hours, 1)                            as hours_remaining,
    case
        when age_hours > timeframe_hours        then 'OVERDUE'
        when age_hours > 0.75 * timeframe_hours then 'AT_RISK'
        else 'ON_TRACK'
    end                                                              as sla_status
from aged
