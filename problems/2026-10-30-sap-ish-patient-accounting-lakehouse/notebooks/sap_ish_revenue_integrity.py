# Databricks notebook source
# MAGIC %md
# MAGIC # SAP IS-H revenue integrity: charges vs 837 claims
# MAGIC Run after the `sap-ish-lakehouse` job (bronze -> silver -> gold).
# MAGIC Reads the gold tables in Unity Catalog and shows where charges and claims disagree.

# COMMAND ----------

dbutils.widgets.text("catalog", "hc_dev")
catalog = dbutils.widgets.get("catalog")

# COMMAND ----------

# MAGIC %md ## Status by department: dollars at risk

# COMMAND ----------

display(spark.sql(f"""
    SELECT department, recon_status, keys, sap_amount, claim_amount, amount_variance
    FROM {catalog}.gold.revenue_integrity_summary
    WHERE recon_status NOT IN ('MATCHED', 'CANCELLED_NOT_BILLED')
    ORDER BY abs(amount_variance) DESC
"""))

# COMMAND ----------

# MAGIC %md ## Work queue: one row per exception, with the SAP postings behind it

# COMMAND ----------

display(spark.sql(f"""
    SELECT r.recon_status, e.case_id_ext AS case_no, e.admitting_department, r.cpt_code,
           r.service_date, r.sap_quantity, r.claim_units, r.sap_amount, r.claim_amount,
           r.sap_service_doc_ids
    FROM {catalog}.gold.recon_charge_vs_claim r
    LEFT JOIN {catalog}.gold.fact_encounter e USING (case_id)
    WHERE r.recon_status NOT IN ('MATCHED', 'CANCELLED_NOT_BILLED')
    ORDER BY r.recon_status, case_no, r.service_date
"""))
