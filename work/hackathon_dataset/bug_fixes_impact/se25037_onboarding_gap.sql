-- LOK-SE25013 (Intrum SE25037): where are the Dec 2025 - Apr 2026 payments that PAM has and our build lacks?
-- GRAIN   one row per payment month. Raw CAT payments on the deal's cases (long_portfolio_id SE25037...),
--         split by whether our build (DEV.HACKATHON) places the case in this deal, against fct_case_collection.
-- COST    only extracts from Dec 2025 on, Swedish systems only; payments deduped on case, date, amount and type.

WITH raw_cases AS (
    SELECT
        SPLIT_PART(SPLIT_PART(_file_path, '/', 3), '.', 2) || '-' || case_id AS case_bk,
        MAX(long_portfolio_id) AS raw_batch_bk,
        MIN(registration_date::date) AS registered
    FROM prod_raw.hyperion_intrum_cat.cases
    WHERE (STARTSWITH(_file_path, 'data-prod-data-raw-sftp-071269be/intrum/cat.1062.cases.202512')
        OR STARTSWITH(_file_path, 'data-prod-data-raw-sftp-071269be/intrum/cat.2080.cases.202512')
        OR STARTSWITH(_file_path, 'data-prod-data-raw-sftp-071269be/intrum/cat.1062.cases.2026')
        OR STARTSWITH(_file_path, 'data-prod-data-raw-sftp-071269be/intrum/cat.2080.cases.2026'))
        AND LEFT(long_portfolio_id, 7) = 'SE25037'
    GROUP BY 1
),

raw_payments AS (
    SELECT DISTINCT
        SPLIT_PART(SPLIT_PART(t._file_path, '/', 3), '.', 2) || '-' || t.case_id AS case_bk,
        t.transaction_date::date AS d,
        -t.amount::DECIMAL(38, 2) AS amount,
        t.amount_type_code,
        t.cost_type,
        t.transaction_type_code
    FROM prod_raw.hyperion_intrum_cat.transactions AS t
    WHERE (STARTSWITH(t._file_path, 'data-prod-data-raw-sftp-071269be/intrum/cat.1062.transactions.2026')
        OR STARTSWITH(t._file_path, 'data-prod-data-raw-sftp-071269be/intrum/cat.2080.transactions.2026'))
        AND t.payment_cost_ind = 'P'
        AND t.amount IS NOT NULL
        AND t.transaction_date BETWEEN '2025-12-01' AND '2026-04-30'
),

model_cases AS (
    SELECT DISTINCT c.case_bk
    FROM dev.hackathon.dim_npl_case AS c
    INNER JOIN dev.hackathon.dim_npl_batch AS b
        ON b.batch_sk = c.batch_sk
    WHERE b.servicer_parent_portfolio_bk = 'SE25037'
),

model_payments AS (
    SELECT LAST_DAY(f.collection_date) AS m, SUM(f.amount) AS fct
    FROM dev.hackathon.fct_npl_case_collection AS f
    INNER JOIN dev.hackathon.dim_npl_batch AS b
        ON b.batch_sk = f.batch_sk
    WHERE b.servicer_parent_portfolio_bk = 'SE25037'
        AND f.collection_date BETWEEN '2025-12-01' AND '2026-04-30'
    GROUP BY 1
),

classified AS (
    SELECT
        LAST_DAY(p.d) AS m,
        p.amount,
        m.case_bk IS NOT NULL AS in_model,
        p.d < rc.registered AS before_registration
    FROM raw_payments AS p
    INNER JOIN raw_cases AS rc
        ON rc.case_bk = p.case_bk
    LEFT JOIN model_cases AS m
        ON m.case_bk = p.case_bk
)

SELECT
    c.m,
    ROUND(SUM(c.amount)) AS raw_cat,
    ROUND(SUM(IFF(c.in_model, c.amount, 0))) AS raw_on_model_cases,
    ROUND(SUM(IFF(NOT c.in_model, c.amount, 0))) AS raw_on_cases_not_in_model,
    ROUND(SUM(IFF(c.before_registration, c.amount, 0))) AS raw_before_case_registered,
    ROUND(MAX(mp.fct)) AS fct_case_collection
FROM classified AS c
LEFT JOIN model_payments AS mp
    ON mp.m = c.m
GROUP BY 1
ORDER BY 1;
