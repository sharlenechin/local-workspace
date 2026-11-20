-- mBank books: every payment record Intrum holds, one row per transaction record.
-- GRAIN   one row per (case_id, pkey): the latest version of each transaction record.
--         build_extract.py collapses records that are one payment and checks the result
--         against PAM month by month (05_pam_monthly.sql) before anything ships.
-- RUN     mise run sql -- work/project-mbank/queries/04_payments.sql \
--             --csv work/project-mbank/.cache/04_payments.csv
-- GUARDS  C2 change history: latest version per (case_id, pkey); C4 instance 2020 pinned as
--         a literal prefix; C5 every extract; C6 payments only (payment_cost_ind = 'P');
--         C7 AMOUNT is sign-flipped, so it is negated here; C11 no date bound.
-- ⚠ booking_ind is returned, not filtered: on 1062 the template's booking_ind guard deleted
--   the whole instance (project-noba/payments_export.sql), so it is measured on 2020 first.
-- ⚠ The payment's date is the latest non-null TRANSACTION_DATE across its versions, so a
--   date carried only by a superseded version is not lost. Undated cash is kept.
SET deals = 'PL19009,PL19017,PL20015,PL20020,PL21024,PL23003';
SET p     = 'data-prod-data-raw-sftp-071269be/intrum/cat.2020.';

WITH
    ids AS (

        SELECT DISTINCT
            case_id
        FROM raw.hyperion_intrum_cat.cases
        WHERE _file_path LIKE $p || 'cases.%'
            AND LEFT(long_portfolio_id, 7) IN (SELECT TRIM(value::STRING) FROM TABLE(SPLIT_TO_TABLE($deals, ',')))
            AND case_id NOT LIKE '%-%'
)

SELECT
    t.case_id,
    t.pkey,
    t.orig_tr_id,
    MAX(t.transaction_date::DATE) OVER (PARTITION BY t.case_id, t.pkey) AS payment_date,
    t.banking_date::DATE AS banking_date,
    -t.amount::NUMBER(38, 2) AS amount,
    t.currency,
    TRIM(t.amount_type_code) AS amount_type_code,
    TRIM(t.transaction_type_code) AS transaction_type_code,
    TRIM(t.booking_ind) AS booking_ind,
    TRIM(t.source) AS source,
    TRIM(t.payment_method) AS payment_method,
    t.installment_plan_id,
    t.settlement_id,
    t.reversed_transaction
FROM raw.hyperion_intrum_cat.transactions AS t
WHERE t._file_path LIKE $p || 'transactions.%'
    AND t.case_id IN (SELECT case_id FROM ids)
    AND t.payment_cost_ind = 'P'
    AND t.amount IS NOT NULL
    AND COALESCE(t.deleted, 0) = 0
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY t.case_id, t.pkey
    ORDER BY COALESCE(t.record_updated, t.update_ts)::TIMESTAMP DESC NULLS LAST
) = 1;
