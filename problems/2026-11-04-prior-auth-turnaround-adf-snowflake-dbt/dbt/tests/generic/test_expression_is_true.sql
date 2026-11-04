{#- Generic test: every row must satisfy the SQL boolean expression. -#}
{% test expression_is_true(model, expression, where='1 = 1', column_name=none) %}
select *
from {{ model }}
where ({{ where }})
  and not ({{ expression }})
{% endtest %}
