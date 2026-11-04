{#-
  dbt run-operation assert_relations_equal --args '{a: marts.x, b: audit.y, exclude: [col]}'
  Fails the run if the two relations differ in any row (EXCEPT both ways).
  Used to prove the incremental fact equals a full refresh.
-#}
{% macro assert_relations_equal(a, b, exclude=[]) %}
    {% set rel_a = adapter.get_relation(database=target.database,
                                        schema=a.split('.')[0], identifier=a.split('.')[1]) %}
    {% set cols = adapter.get_columns_in_relation(rel_a)
                  | map(attribute='name') | reject('in', exclude) | list %}
    {% set col_list = cols | join(', ') %}
    {% set sql %}
        select
            (select count(*) from {{ a }}) as rows_a,
            (select count(*) from {{ b }}) as rows_b,
            (select count(*) from (select {{ col_list }} from {{ a }}
                                   except select {{ col_list }} from {{ b }}) x) as only_in_a,
            (select count(*) from (select {{ col_list }} from {{ b }}
                                   except select {{ col_list }} from {{ a }}) y) as only_in_b
    {% endset %}
    {% set r = run_query(sql).rows[0] %}
    {{ log("compare " ~ a ~ " vs " ~ b ~ " on " ~ cols | length ~ " columns: rows_a=" ~ r[0]
           ~ " rows_b=" ~ r[1] ~ " only_in_a=" ~ r[2] ~ " only_in_b=" ~ r[3], info=true) }}
    {% if r[0] != r[1] or r[2] != 0 or r[3] != 0 %}
        {{ exceptions.raise_compiler_error("Relations differ: " ~ a ~ " vs " ~ b) }}
    {% endif %}
{% endmacro %}
