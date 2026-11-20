-- ============================================================================
-- pt_pam_coverage — what Portuguese collection history exists in the Intrum PAM
-- feed, i.e. whether a Portugal REFERENCE PORTFOLIO can be built the way the
-- Swedish one was for the npl-underwriting target model.
--
--   RUN    mise run sql -- work/portugal/pt_pam_coverage.sql
--   GRAIN  one row per serviceline x product branch x deal type.
--   SOURCE raw.hyperion_intrum_pam.pam, the same single monthly file and the
--          same four guards as work/average_balance/reference_data.sql, which
--          builds the Swedish reference input. Read-only, NPL_ANALYST.
--
-- WHY. The target model fits a decay curve on the deal's own payments while
-- partially pooling it with a reference book of the same product type. That
-- reference book is PAM, not a seller tape — so a thin benchmark/tape position
-- in Portugal does not by itself block the approach. This counts what is there.
--
-- Guards carried over from reference_data.sql, unchanged:
--   G1 pin the file BY NAME ('pam_perimeter' files land seconds later and carry
--      none of these columns, so a newest-timestamp pick returns zero rows)
--   G2 'Adjust' rows are internal accounting, not the book
--   G3 ownership-transfer rows repeat a segment-month and would double cash
--   G4 cut forecast months at the FILE's extract month, not today's
-- ============================================================================

SET country = 'PT';


WITH newest_delivery AS (
    SELECT MAX(_file_path) AS file_path
    FROM raw.hyperion_intrum_pam.pam
    WHERE _file_path LIKE '%/pam.pam.pam.2%'                             -- G1
),

heimdall AS (
    SELECT
        p.combined_ref,
        LEFT(p.period_start_date, 10)::date AS period_month,
        LEFT(p.capex_date_m, 10)::date      AS capex_month,
        p.serviceline,
        p.branch_desc,
        p.deal_type_desc,
        p.currency,
        p.seller_name,
        p.colltotal,
        p.acqcases,
        p.acquisitionprincipal,
        DATE_TRUNC('month',
            TO_TIMESTAMP_NTZ(
                PARSE_JSON(p._file_metadata):extract_ts::string,
                'YYYYMMDDTHH24MISS'))::date AS extract_month
    FROM raw.hyperion_intrum_pam.pam AS p
    INNER JOIN newest_delivery AS nd
        ON p._file_path = nd.file_path                                   -- G1
    WHERE p.countrycode = $country
      AND p.pmode_name  = 'Real'                                        -- G2
      AND COALESCE(p.is_ownership_change, 0) = 0                        -- G3
),

actual_months AS (
    SELECT * FROM heimdall WHERE period_month < extract_month           -- G4
),

segment_months AS (
    -- One row per segment-month, so a month is counted once however many
    -- source rows make it up.
    SELECT
        combined_ref,
        serviceline,
        branch_desc,
        deal_type_desc,
        currency,
        capex_month,
        period_month,
        SUM(colltotal)            AS payment_amount,
        MAX(acqcases)             AS n_accounts,
        MAX(acquisitionprincipal) AS total_balance
    FROM actual_months
    GROUP BY 1, 2, 3, 4, 5, 6, 7
)

SELECT
    serviceline,
    branch_desc,
    deal_type_desc,
    COUNT(DISTINCT combined_ref)                   AS segments,
    COUNT(DISTINCT currency)                       AS currencies,
    MIN(capex_month)                               AS first_purchase,
    MAX(capex_month)                               AS last_purchase,
    MIN(period_month)                              AS first_month,
    MAX(period_month)                              AS last_month,
    -- Months with a payment row, per segment: the length of history the decay
    -- curve actually has to sit on.
    ROUND(COUNT(*) / NULLIF(COUNT(DISTINCT combined_ref), 0), 2) AS avg_months_per_segment,
    SUM(payment_amount)                            AS collections,
    SUM(DISTINCT total_balance)                    AS acquisition_principal
FROM segment_months
GROUP BY 1, 2, 3
ORDER BY segments DESC;
