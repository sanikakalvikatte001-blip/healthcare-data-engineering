{#- Local-run helpers used by run_local.sh (not needed in production). -#}

{% macro clone_relation(from, to) %}
    {% do run_query("create schema if not exists " ~ to.split('.')[0]) %}
    {% do run_query("create or replace table " ~ to ~ " as select * from " ~ from) %}
    {{ log("cloned " ~ from ~ " -> " ~ to, info=true) }}
{% endmacro %}

{% macro export_results() %}
    {% set exports = {
        'mart_pa_turnaround_monthly': 'select * from marts.mart_pa_turnaround_monthly order by 1, 2, 3',
        'mart_pa_open_overdue': 'select * from marts.mart_pa_open_overdue order by hours_remaining, request_id',
        'snap_pa_request_changes': "select request_id, priority, service_category, dbt_valid_from, dbt_valid_to from snapshots.snap_pa_request where request_id in (select request_id from snapshots.snap_pa_request group by 1 having count(*) > 1) order by 1, dbt_valid_from"
    } %}
    {% for name, sql in exports.items() %}
        {% do run_query("copy (" ~ sql ~ ") to '../output/" ~ name ~ ".csv' (header)") %}
        {{ log("exported output/" ~ name ~ ".csv", info=true) }}
    {% endfor %}
{% endmacro %}
