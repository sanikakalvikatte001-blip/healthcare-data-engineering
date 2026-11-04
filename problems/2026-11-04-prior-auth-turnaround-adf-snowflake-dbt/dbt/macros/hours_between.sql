{#- Fractional hours between two timestamps, portable across Snowflake/DuckDB. -#}
{% macro hours_between(start_ts, end_ts) -%}
    ({{ dbt.datediff(start_ts, end_ts, 'minute') }} / 60.0)
{%- endmacro %}

{#- The as-of timestamp used for open-request aging. -#}
{% macro as_of_ts() -%}
    {%- if var('as_of_ts') is none -%}
        {{ dbt.current_timestamp() }}
    {%- else -%}
        cast('{{ var("as_of_ts") }}' as {{ dbt.type_timestamp() }})
    {%- endif -%}
{%- endmacro %}
