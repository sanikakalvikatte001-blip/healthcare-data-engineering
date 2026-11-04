-- provider_sk is unique (hash keys must not collide).
CREATE OR REPLACE VIEW tests.assert_dim_surrogate_key_unique AS
SELECT provider_sk, count(*) AS n
FROM marts.dim_provider
GROUP BY provider_sk
HAVING count(*) > 1;
