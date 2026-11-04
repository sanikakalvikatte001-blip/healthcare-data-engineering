-- One row per status event: the latest version received. A decision keyed
-- wrong and corrected in the UM platform keeps its event_id, so the corrected
-- version replaces the original here.
with source as (
    select * from {{ source('um', 'pa_status_event') }}
),

latest as (
    select *
    from source
    qualify row_number() over (
        partition by event_id
        order by cast(modified_at as {{ dbt.type_timestamp() }}) desc, _loaded_at desc
    ) = 1
)

select
    trim(event_id)                                     as event_id,
    trim(request_id)                                   as request_id,
    upper(trim(status))                                as status,
    cast(event_at as {{ dbt.type_timestamp() }})       as event_at,
    nullif(trim(reason_code), '')                      as reason_code,
    cast(modified_at as {{ dbt.type_timestamp() }})    as source_modified_at,
    _loaded_at
from latest
