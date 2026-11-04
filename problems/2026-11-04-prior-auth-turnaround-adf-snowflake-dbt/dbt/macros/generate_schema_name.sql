{#-
  Use the folder's custom schema as-is (staging, intermediate, marts, snapshots)
  instead of dbt's default "<target_schema>_<custom>" concatenation, so the
  Snowflake layout is ANALYTICS.STAGING / ANALYTICS.MARTS etc.
-#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
