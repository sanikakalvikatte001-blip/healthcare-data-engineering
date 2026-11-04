-- The open (current) snapshot version of every request must equal the latest
-- staged values, and each request has exactly one current version.
with current_versions as (
    select request_id, priority, service_category, procedure_code,
           count(*) over (partition by request_id) as current_rows
    from {{ ref('snap_pa_request') }}
    where dbt_valid_to is null
)

select s.request_id, s.priority, c.priority as snapshot_priority, c.current_rows
from {{ ref('stg_um__pa_requests') }} s
left join current_versions c on c.request_id = s.request_id
where c.request_id is null
   or c.current_rows <> 1
   or c.priority <> s.priority
   or c.service_category <> s.service_category
   or c.procedure_code <> s.procedure_code
