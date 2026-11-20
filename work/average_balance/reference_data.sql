-- ============================================================================
-- reference_data — Heimdall (Intrum PAM) reference data for the target
-- modelling pipeline. Replaces the original extract; SAME COLUMNS, SAME GRAIN.
--
--   RUN    mise run sql -- work/average_balance/reference_data.sql
--   GRAIN  one row per segment per month — REQUIRED. payment_date +
--          payment_amount are a time series, and the pipeline derives
--          mean_balance = total_balance / n_accounts per row.
--   FEEDS  npl-underwriting TargetModelCleanedPortfolioSchema
--   WHY    README.md
--
-- ⚠ DO NOT RENAME COLUMNS. pandera validates on these exact names.
-- ⚠ n_accounts and total_balance REPEAT on every month of a segment. That is
--   correct — they are fixed at purchase. Per row they are right; only an
--   aggregate across rows would need de-duplicating first (README.md).
--
-- CHANGED FROM THE ORIGINAL — three guards, measured 2026-10-05:
--   G1 pin the file BY NAME, not by newest timestamp
--   G3 drop ownership-transfer duplicate rows
--   G4 cut forecast months at the FILE's date, not today's
--      -> removes one fake zero-payment month from all 1,557 segments
--   Plus: cast the two date columns (raw holds VARCHAR; pandera wants DateTime)
-- ⚠ Nothing may follow the final semicolon.
-- ============================================================================

SET country     = 'SE';
SET serviceline = 'PI Unsecured';
SET deal_type   = 'Ongoing';


WITH newest_delivery AS (
    -- G1. One monthly file, chosen BY NAME.
    -- ⚠ The original used max(_file_last_modified) over the whole table. Six
    --   'pam_perimeter' files have been loaded into this table, each 1-3 SECONDS
    --   AFTER the pam file beside it, and they carry none of these columns — so
    --   a newest-timestamp pick would return ZERO ROWS WITH NO ERROR. Harmless
    --   today only because those stopped after 2026-01-14.
    SELECT MAX(_file_path) AS file_path
    FROM raw.hyperion_intrum_pam.pam
    WHERE _file_path LIKE '%/pam.pam.pam.2%'
),

heimdall AS (
    SELECT
        p.combined_ref,
        -- Raw holds these as VARCHAR. period_start_date is the FIRST DAY of the
        -- reporting month; capex_date_m is when INTRUM bought the tranche.
        LEFT(p.period_start_date, 10)::date AS period_month,
        LEFT(p.capex_date_m, 10)::date      AS capex_month,
        p.countrycode,
        p.branch_desc,
        p.deal_type_desc,
        p.currency,
        p.seller_name,
        p.colltotal,
        p.acqcases,
        p.average_debt_age,
        p.acquisitionprincipal,
        -- G4 input: the actual/forecast boundary is this FILE's extract month.
        DATE_TRUNC('month',
            TO_TIMESTAMP_NTZ(
                PARSE_JSON(p._file_metadata):extract_ts::string,
                'YYYYMMDDTHH24MISS'))::date AS extract_month
    FROM raw.hyperion_intrum_pam.pam AS p
    INNER JOIN newest_delivery AS nd
        ON p._file_path = nd.file_path                                   -- G1
    WHERE p.countrycode    = $country
      AND p.serviceline    = $serviceline
      AND p.deal_type_desc = $deal_type
      -- G2. 'Adjust' rows are internal accounting, not the book.
      -- ⚠ This does NOT separate actuals from forecast. 100% of rows here are
      --   'Real', including months out to 2040-11-01. Only G4 holds forecast out.
      AND p.pmode_name = 'Real'
      -- G3. An ownership transfer repeats a segment-month, which would DOUBLE
      -- payment_amount. None in Sweden, but 3,075 such rows in CH and 131 in PL
      -- on this same file — and this extract is meant to be re-pointed at other
      -- countries, so the guard travels with the feed, not with the country.
      AND COALESCE(p.is_ownership_change, 0) = 0
),

actual_months AS (
    -- G4. The original cut at today's month end. This file was produced
    -- 2026-09-10 and runs about a month behind, so one forecast month slipped
    -- through on EVERY segment — 1,557 rows whose payment_amount is 0. A
    -- trailing fake zero distorts any decay curve fitted to the series.
    SELECT * FROM heimdall WHERE period_month < extract_month
)

SELECT
    combined_ref          AS segment_id,
    period_month          AS payment_date,
    countrycode           AS country,
    branch_desc           AS product_type,
    deal_type_desc        AS deal_type,
    capex_month           AS registration_date,
    currency,
    seller_name,
    -- ⚠ colltotal only, matching the original. The warehouse also counts
    --   salesproceeds as cash recovered — SEK 1,388,978.48 here, 0.059% of the
    --   total. Adding it would change the modelled target, so it is left as a
    --   deliberate choice rather than a silent one. See README.md.
    SUM(colltotal)        AS payment_amount,
    -- Fixed at purchase, so identical on every row of a segment: MAX() is an
    -- identity here, not a choice between values. Verified 2026-10-05 — 0 of
    -- 1,557 segments carry more than one value of any of these three.
    MAX(acqcases)         AS n_accounts,
    MAX(average_debt_age) AS avg_debt_age,
    MAX(acquisitionprincipal) AS total_balance
FROM actual_months
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
ORDER BY payment_date DESC;
