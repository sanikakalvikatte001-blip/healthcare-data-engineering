{#-
  One row per prior authorization request (grain: request_id).

  Incremental: each run re-processes only requests touched by a newer load
  (a new/changed header OR any new/changed status event), then upserts them.
  Snowflake uses MERGE; DuckDB (local/CI) uses delete+insert - same result.
  The local run proves incremental == full refresh (see run_local.sh).
-#}
{{
    config(
        materialized = 'incremental',
        unique_key = 'request_id',
        incremental_strategy = 'merge' if target.type == 'snowflake' else 'delete+insert',
        on_schema_change = 'append_new_columns'
    )
}}

with lifecycle as (
    select * from {{ ref('int_pa_request_lifecycle') }}
    {% if is_incremental() %}
    where last_loaded_at > (select coalesce(max(last_loaded_at), cast('1900-01-01' as {{ dbt.type_timestamp() }}))
                            from {{ this }})
    {% endif %}
)

select
    request_id,
    member_id,
    requesting_npi,
    line_of_business,
    service_category,
    procedure_code,
    submission_channel,
    priority,
    received_at,
    cast(received_at as date)                                   as received_date,
    determination_at,
    cast({{ dbt.date_trunc('month', 'determination_at') }} as date) as determination_month,
    determination_status,
    determination_reason,
    lifecycle_status,
    pend_count,
    round(pend_hours, 2)                                        as pend_hours,
    timeframe_hours,
    round(turnaround_hours, 2)                                  as turnaround_hours,
    case when turnaround_hours is null then null
         else turnaround_hours <= timeframe_hours end           as met_timeframe,
    event_count,
    last_loaded_at
from lifecycle
