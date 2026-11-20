-- CAT side, yearly collections per deal, for comparison with PAM COLLTOTAL.
-- Deals SE15044 and SE16025 (Swedish systems 1062 Nova DS and 2080 Nova Varberg).
-- Grain: one row per deal x calendar year of payment.
WITH cases AS (
    -- One row per case. CAT resends every case on each update, so keep the newest version.
    -- A case id is unique only within a system, so the system is part of the key.
    SELECT
        LEFT(c.long_portfolio_id, 7) AS deal,
        PARSE_JSON(c._file_metadata):system::STRING AS source_system,
        c.case_id
    FROM RAW.HYPERION_INTRUM_CAT.cases AS c
    WHERE (STARTSWITH(c._file_path, 'data-prod-data-raw-sftp-071269be/intrum/cat.1062.cases.')
        OR STARTSWITH(c._file_path, 'data-prod-data-raw-sftp-071269be/intrum/cat.2080.cases.'))
        AND LEFT(c.long_portfolio_id, 7) IN ('SE15044', 'SE16025')
        AND c.case_id NOT LIKE '%-%'                 -- hyphenated ids are sub-cases, not loans
        AND COALESCE(c.real_case_ind, '') <> '1'     -- grouping rows, not loans
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY source_system, c.case_id
        ORDER BY COALESCE(c.record_updated, c.update_ts)::TIMESTAMP DESC NULLS LAST
    ) = 1
),

payments AS (
    -- One row per payment. The feed resends each payment on every update, and
    -- orig_tr_id does not identify a payment here: one payment arrives under several ids.
    -- amount_type_code stays in the key because one payment is legitimately split
    -- across several amount types.
    SELECT
        c.deal,
        t.transaction_date::DATE AS payment_date,
        -t.amount::DECIMAL(38, 2) AS amount         -- stored sign-flipped
    FROM RAW.HYPERION_INTRUM_CAT.transactions AS t
    INNER JOIN cases AS c
        ON c.case_id = t.case_id
        AND c.source_system = PARSE_JSON(t._file_metadata):system::STRING
    WHERE (STARTSWITH(t._file_path, 'data-prod-data-raw-sftp-071269be/intrum/cat.1062.transactions.')
        OR STARTSWITH(t._file_path, 'data-prod-data-raw-sftp-071269be/intrum/cat.2080.transactions.'))
        AND t.payment_cost_ind = 'P'                 -- payments, not costs
        AND t.amount IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY c.source_system, t.case_id, t.transaction_date::DATE,
            t.amount_type_code, t.amount
        ORDER BY COALESCE(t.record_updated, t.update_ts)::TIMESTAMP DESC NULLS LAST
    ) = 1
)

SELECT
    deal,
    YEAR(payment_date) AS yr,
    SUM(amount) AS cat_collections
FROM payments
GROUP BY 1, 2
ORDER BY 1, 2;
