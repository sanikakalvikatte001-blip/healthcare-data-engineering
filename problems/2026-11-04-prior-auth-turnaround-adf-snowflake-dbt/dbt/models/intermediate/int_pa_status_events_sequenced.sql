-- Orders each request's events and pairs every PENDED_INFO with the event
-- that ends the pend (INFO_RECEIVED, or a decision made without the info).
with events as (
    select * from {{ ref('stg_um__pa_status_events') }}
),

sequenced as (
    select
        event_id,
        request_id,
        status,
        event_at,
        reason_code,
        _loaded_at,
        row_number() over (partition by request_id order by event_at, event_id) as event_seq,
        lead(event_at) over (partition by request_id order by event_at, event_id) as next_event_at,
        status in ('APPROVED', 'DENIED', 'PARTIAL_APPROVED')                     as is_determination
    from events
)

select
    *,
    case when status = 'PENDED_INFO' and next_event_at is not null
         then {{ hours_between('event_at', 'next_event_at') }}
    end as pend_hours
from sequenced
