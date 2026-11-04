-- One row per prior authorization request: the latest version received.
-- Raw is append-only, so a request re-extracted in an overlap window or
-- re-sent after a reclassification shows up more than once.
with source as (
    select * from {{ source('um', 'pa_request') }}
),

latest as (
    select *
    from source
    qualify row_number() over (
        partition by request_id
        order by cast(modified_at as {{ dbt.type_timestamp() }}) desc, _loaded_at desc
    ) = 1
)

select
    trim(request_id)                                   as request_id,
    trim(member_id)                                    as member_id,
    trim(requesting_npi)                               as requesting_npi,
    upper(trim(line_of_business))                      as line_of_business,
    upper(trim(service_category))                      as service_category,
    upper(trim(procedure_code))                        as procedure_code,
    upper(trim(submission_channel))                    as submission_channel,
    upper(trim(priority))                              as priority,
    cast(received_at as {{ dbt.type_timestamp() }})    as received_at,
    cast(modified_at as {{ dbt.type_timestamp() }})    as source_modified_at,
    _loaded_at
from latest
