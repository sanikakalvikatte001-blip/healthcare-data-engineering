-- One row per request with its lifecycle milestones and turnaround.
-- Turnaround = calendar hours from receipt to the FIRST determination
-- (approved / denied / partially approved). Pended time is reported
-- separately and is not subtracted from the regulatory clock.
with requests as (
    select * from {{ ref('stg_um__pa_requests') }}
),

events as (
    select * from {{ ref('int_pa_status_events_sequenced') }}
),

event_rollup as (
    select
        request_id,
        min(case when is_determination then event_at end)                 as determination_at,
        min(case when status = 'WITHDRAWN' then event_at end)             as withdrawn_at,
        count(case when status = 'PENDED_INFO' then 1 end)                as pend_count,
        coalesce(sum(pend_hours), 0)                                      as pend_hours,
        max(event_seq)                                                    as event_count,
        max(_loaded_at)                                                   as events_loaded_at
    from events
    group by request_id
),

first_determination as (
    select request_id, status as determination_status, reason_code as determination_reason
    from events
    where is_determination
    qualify row_number() over (partition by request_id order by event_at, event_id) = 1
)

select
    r.request_id,
    r.member_id,
    r.requesting_npi,
    r.line_of_business,
    r.service_category,
    r.procedure_code,
    r.submission_channel,
    r.priority,
    r.received_at,
    e.determination_at,
    d.determination_status,
    d.determination_reason,
    e.withdrawn_at,
    coalesce(e.pend_count, 0)                                             as pend_count,
    coalesce(e.pend_hours, 0)                                             as pend_hours,
    coalesce(e.event_count, 0)                                            as event_count,
    case r.priority
        when 'EXPEDITED' then {{ var('expedited_timeframe_hours') }}
        else {{ var('standard_timeframe_hours') }}
    end                                                                   as timeframe_hours,
    case when e.determination_at is not null
         then {{ hours_between('r.received_at', 'e.determination_at') }}
    end                                                                   as turnaround_hours,
    case
        when e.determination_at is not null       then 'DETERMINED'
        when e.withdrawn_at is not null           then 'WITHDRAWN'
        else 'OPEN'
    end                                                                   as lifecycle_status,
    -- drives the incremental fact: newest load that touched this request
    greatest(r._loaded_at, coalesce(e.events_loaded_at, r._loaded_at))    as last_loaded_at
from requests r
left join event_rollup e        on e.request_id = r.request_id
left join first_determination d on d.request_id = r.request_id
