-- Project NOBA payments: one series per loan, each payment from whichever source knows it.
-- GRAIN   one row per (loan_id, payment_date, payment_source). CASE level, not borrower.
-- RUN     mise run sql -- work/project-noba/payments_export.sql \
--             --connection dev --warehouse DEV_WH --lower
-- PAIRS   accounts_export.sql on (portfolio_id, loan_id).
-- INSTANCES  1062 and 2080 are both read: of 555 Swedish deals, 266 sit on BOTH and
--         CASE_ID is unique only within one, so the instance is read off _file_path and
--         joined on as well. SE15044 and SE16025 are 2080-only, so this changes nothing
--         for them; it makes the file safe to point at another Swedish deal.
-- SOURCE  before the servicer took the case on, only the seller knew the payment, so it
--         comes from the tape; from the registration date onward CAT is the servicer's
--         own record and is used instead. PAYMENT_SOURCE says which, per row, so the
--         two are never silently mixed and either can be dropped.
-- ⚠ THE SERIES STARTS BEFORE WE OWNED THE BOOK. SE15044's first payment is 1997 against
--   a 2015-12-01 purchase. Summing the lot gives the seller's collections as well as
--   ours, which is not a recovery rate on what we paid. IS_POST_ACQUISITION splits it.
-- ⚠ A loan registered before its first CAT payment but absent from the tape has no
--   pre-registration history at all -- missing, not zero.
-- WHY REGISTRATION IS THE BOUNDARY, measured 2026-11-02:
--   · the tape is NOT cut at its cut-off date -- SE15044's cut-off is 2015-12-15 and its
--     tape payments run to 2026-10-09, 183,542 rows after it. The two sources overlap
--     for ten years, and splitting here is what stops them being counted twice.
--   · SE16025 HAS NO CUT-OFF AT ALL: cutoff_date is NULL on all 3,297 of its tape
--     cases, and only 1,176 of its 57,781 tape payments (2%) predate the 2016-12
--     purchase, against 57% on SE15044. Its tape is a servicing extract running to
--     2026-10-12, not a diligence tape, so SE16025 carries almost no pre-purchase
--     payment behaviour. A gap, not an error -- the split still stops double counting.
--   · A CUT-OFF MUST PRECEDE ACQUISITION, and SE15044 appears to break that rule:
--     cut 2015-12-15 against a 2015-12-01 capex date. The capex date is what is coarse,
--     not the cut-off. LEGACY_CAPEX_DATE is month-grain -- 11,733 of the warehouse's
--     11,793 batches fall on the 1st (99.49%, only 294 distinct dates, measured
--     2026-11-03), so it names the month of purchase. Read in that order SE15044 is
--     consistent: cut 2015-12-15, then registered from January 2016 (median 2016-01-08).
--     ⚠ This file and reconciliation.sql both use LEGACY_CAPEX_DATE as the
--       post-acquisition boundary, so that boundary is accurate to the month, not the
--       day, and can admit a few weeks of pre-completion cash. Too small to matter here
--       -- it cannot make a whole year read 151% of PAM -- but do not quote it as exact.
--   · CAT holds almost nothing before registration (0 rows on SE15044, SE16025 and
--     SE20009; 2 rows, 794 kr, on SE19026), so the boundary discards no money.
--   · after acquisition CAT is the better source. SE15044: tape 165,166,718, CAT
--     195,318,189, PAM 193,716,635 -- CAT agrees with Intrum's own report to 0.8%
--     while the seller's file is 15% short.
-- RECONCILES against PAM post-acquisition, measured 2026-11-02 with reconciliation.sql:
--   SE19026 99.3%, SE20009 98.8%, SE25018 102.0%, SE16025 120.7%, SE15044 127.7%,
--   SE25037 87.6%. Compare on THAT basis, never post-registration: PAM only counts cash
--   collected since we bought the book, and on a 2025 book the two differ by a factor of
--   four (SE25018 reads 385% post-registration and 102% post-acquisition).
-- ⚠ ON THE TWO OLDEST BOOKS THE WHOLE EXCESS IS IN 2016-2019 AND IS NOT OURS. Measured
--   by year, 2026-11-02: SE15044 runs 151% / 166% / 180% / 121% of PAM across 2016, 2017,
--   2018 and 2019, then 98.5-100.2% every year from 2020 on. SE16025 does the same --
--   136% / 163% / 180% / 123%, then 99.8-104.7%. Those four years hold 54.9m of SE15044's
--   53.7m total gap and 22.3m of SE16025's 22.7m, so after 2019 the two sources agree as
--   closely as they do on SE19026 and SE20009, which were bought after it and are clean
--   throughout. Two unrelated books, two sellers, the same peak year and the same snap to
--   parity in 2020: this is a change in Intrum's own batch reporting, not a defect in this
--   query and not a property of either book. RULED OUT BY MEASUREMENT, same date: payment
--   type (all four deals carry the same three AMOUNT_TYPE_CODEs, and the two clean ones
--   reconcile with all of them in), duplicate payment histories across split cases (0.06%
--   of SE15044 and 0.03% of SE16025, against 0.11% on the clean SE20009), and REF_CASE_ID
--   as a parent-case link (100% NULL on all six deals).
--   So CASH SINCE 2020 IS QUOTABLE ON ALL FOUR OLD BOOKS. A lifetime recovery rate on
--   SE15044 or SE16025 is not, until Intrum explains what PAM leaves out of those years.
-- ⚠ SE25018 AND SE25037 ARE 2025 BOOKS AND THE PAM SIDE IS NOT GUARDED AGAINST FORECAST
--   MONTHS. PAM carries projected collections as well as actual ones and the comparison
--   cuts only on pmode_name = 'Real', not at the extract file's own month. Almost all of a
--   2025 book's curve is still in the future, so SE25037's 87.6% may be a collected-to-date
--   figure against a collected-plus-projected one. Confirm before treating it as a gap.
--   Our figure equals dbt's to the ore on both, from a different code path.
-- ⚠ CAT transaction dates on this instance run to the year 2121. Never bound the date:
--   sentinel years sit on superseded versions and a bound deletes real money instead.

-- ⚠ STATE OF THE EIGHT DEALS, measured 2026-11-02. Every one is in PAM, but:
--   · FIVE of the six now have an approved asset-index run -- all but SE25018. Measured
--     2026-11-03, the share of the loans we own that the tape actually reaches is
--     SE19026 92.3%, SE25037 90.6%, SE15044 72.8%, SE16025 27.9%, and SE20009 0%:
--     SE20009 HAS a run, but none of its tape ids join to a CAT case, so its tape
--     columns come back NULL exactly as SE25018's do. A loan the tape never reached is
--     still a row -- the base is what we own, not what the seller sent.
--   · SIX DEALS, NOT EIGHT. SE25008 and SE25013 are OUR Atlas ids for two books Intrum
--     knows as SE25018 and SE25037, so listing all four would name two books twice.
--     Confirmed 2026-11-02: DIM_BATCH, which is keyed on the servicer's id, holds only
--     SE25018 (Santander Consumer Bank, capex 2025-06-01, 9,713 cases) and SE25037
--     (Norion Bank, 2025-12-01, 2,341 cases); SE25008 and SE25013 exist only in
--     DIM_PORTFOLIO, which is keyed on ours. CAT and PAM both go by the servicer's id,
--     so that is what this file asks for.
--   · SE19026, SE25018 and SE25037 span instances 1062 AND 2080; the rest are 2080 only.
SET deals      = 'SE15044,SE16025,SE19026,SE20009,SE25018,SE25037';
SET raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.';

WITH
    deals_asked_for AS (

        SELECT
            TRIM(value::string) AS deal
        FROM TABLE(SPLIT_TO_TABLE($deals, ','))
        WHERE TRIM(value::string) <> ''
),

    batches AS (

        SELECT DISTINCT
            combined_ref
        FROM prod_raw.hyperion_intrum_pam.pam
        WHERE _file_path = (
                SELECT MAX(_file_path)
                FROM prod_raw.hyperion_intrum_pam.pam
                WHERE _file_path LIKE '%/pam.pam.pam.2%'
            )
            AND pmode_name = 'Real'
            AND COALESCE(is_ownership_change, 0) = 0
            AND portfolioid IN (SELECT deal FROM deals_asked_for)
),

-- Identical spine to accounts_export.sql, carrying the date that splits the series.
    owned AS (

        SELECT
            LEFT(c.long_portfolio_id, 7) AS portfolio_id,
            PARSE_JSON(c._file_metadata):system::string AS source_system,
            c.case_id AS loan_id,
            PARSE_JSON(c._file_metadata):system::string
                || '-' || c.case_id AS case_bk,
            c.registration_date::date AS registration_date
        FROM prod_raw.hyperion_intrum_cat.cases AS c
        WHERE (c._file_path LIKE $raw_prefix || '1062.cases.%'
                OR c._file_path LIKE $raw_prefix || '2080.cases.%')
            AND c.long_portfolio_id IN (SELECT combined_ref FROM batches)
            AND c.case_id NOT LIKE '%-%'
            -- Everything but '1'. real_case_ind = 'R' looks like the acquired case and
            -- fixes SE16025's count (245% -> 94.6%), but it costs principal where it
            -- matters: SE15044 drops to 78.4% of the principal we bought, against 95.4%
            -- here. Measured both ways 2026-11-02 with reconciliation.sql.
            AND COALESCE(c.real_case_ind, '') <> '1'
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY PARSE_JSON(c._file_metadata):system::string,
                c.case_id
            ORDER BY COALESCE(c.record_updated, c.update_ts)::timestamp DESC NULLS LAST
        ) = 1
),

-- The asset index does NOT file every book under the id CAT and PAM use. SE25018's tape
-- is filed under SE25008, our own Atlas id for the same Santander book; SE25037's is
-- filed under Intrum's number. Measured 2026-11-03: without this mapping SE25018 reports
-- "no seller tape" while its tape sits in the index, approved and unread.
    tape_alias AS (

        SELECT
            d.deal,
            COALESCE(a.index_id, d.deal) AS index_id
        FROM deals_asked_for AS d
        LEFT JOIN (
            SELECT 'SE25018' AS deal, 'SE25008' AS index_id
        ) AS a
            ON a.deal = d.deal
),

    latest_run AS (

        SELECT
            t.deal AS portfolio_id,          -- mapped back to the id CAT and PAM use
            r.run_id
        FROM asset_index.approved.runs AS r
        INNER JOIN tape_alias AS t
            ON t.index_id = r.portfolio_id
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY r.deal_key
            ORDER BY r.approved_at DESC
        ) = 1
),

-- Everything the seller knew before the servicer took the case on.
    seller_payments AS (

        SELECT
            o.portfolio_id,
            o.source_system,
            o.loan_id,
            p.payment_date::date AS payment_date,
            'seller tape' AS payment_source,
            p.payment_amount AS amount
        FROM latest_run AS r
        INNER JOIN asset_index.approved.payments AS p
            ON p._run_id = r.run_id
        INNER JOIN owned AS o
            ON o.case_bk = p.case_id
        WHERE p.payment_date < o.registration_date
),

-- Everything the servicer has collected since. One row per real payment.
    servicer_payments AS (

        SELECT
            portfolio_id,
            source_system,
            loan_id,
            payment_date,
            'servicer (CAT)' AS payment_source,
            amount
        FROM (
            SELECT
                o.portfolio_id,
                o.source_system,
                o.loan_id,
                o.registration_date,
                t.amount_type_code,
                -- Latest non-null date across every version of this transaction id.
                MAX(t.transaction_date::date) OVER (
                    PARTITION BY o.source_system, t.case_id,
                        CONCAT(t.orig_tr_id, COALESCE(t.pkey, ''))
                ) AS payment_date,
                -t.amount::decimal(38, 2) AS amount,         -- C7: stored sign-flipped
                COALESCE(t.record_updated, t.update_ts)::timestamp AS record_update,
                TO_TIMESTAMP_NTZ(PARSE_JSON(t._file_metadata):extract_ts::string,
                    'YYYYMMDDTHH24MISS') AS extracted_at
            FROM prod_raw.hyperion_intrum_cat.transactions AS t
            INNER JOIN owned AS o
                ON o.loan_id = t.case_id
                -- Instance as well as case_id: the id repeats across the two.
                AND o.source_system
                    = PARSE_JSON(t._file_metadata):system::string
            WHERE (t._file_path LIKE $raw_prefix || '1062.transactions.%'
                    OR t._file_path LIKE $raw_prefix || '2080.transactions.%')
                AND t.payment_cost_ind = 'P'                  -- C6: payments, not costs
                -- NO booking_ind GUARD. The template excludes booking_ind = 'Y' on
                -- Intrum's instruction, which is right on 2080 where the column is null
                -- on all 341m rows and the guard is inert. On 1062 it is the opposite:
                -- measured 2026-11-02, every one of the 5,910,892 payment rows carrying
                -- an amount is 'Y', and all 1,333,586 rows that are not 'Y' have no
                -- amount at all. Applying the guard there deleted the whole instance --
                -- SE25018 reported 7.9% of PAM because 70% of its loans live on 1062.
                AND t.amount IS NOT NULL
        )
        -- An undated payment cannot be placed either side of registration, so it is kept
        -- and flagged by a null payment_date rather than dropped.
        WHERE payment_date >= registration_date OR payment_date IS NULL
        -- NOT the team's ORIG_TR_ID key, which does not work on this feed: one payment
        -- arrives under many ids (case 2080-1212023 has 14 rows of exactly 570.00 on
        -- 2016-01-27, each with its own orig_tr_id). Keyed instead on what identifies a
        -- real payment. AMOUNT_TYPE_CODE stays in the key because a payment is split
        -- across three of them legitimately, on every book here.
        -- Measured 2026-11-02 against PROD.NPL_COMMON.FCT_CASE_COLLECTION: SE15044
        -- +1.6%, SE16025 +2.4%, SE19026 +0.2%, SE20009 +0.2%. On the ORIG_TR_ID key the
        -- first two were +271% and +147%.
        -- ⚠ Two genuine payments of the same amount, same type, same loan, same day
        --   collapse into one. That undercount is small and known; the alternative
        --   overstates SE15044 by a factor of four.
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY source_system, loan_id, payment_date, amount_type_code, amount
            ORDER BY record_update DESC NULLS LAST, extracted_at DESC
        ) = 1
),

    acquisition AS (

        SELECT
            b.servicer_parent_portfolio_bk AS portfolio_id,
            MIN(b.legacy_capex_date) AS acquisition_date
        FROM prod_npl_common.npl_common.dim_batch AS b
        WHERE b.servicer_parent_portfolio_bk IN (SELECT deal FROM deals_asked_for)
        GROUP BY 1
),

    combined AS (

        SELECT * FROM seller_payments
        UNION ALL
        SELECT * FROM servicer_payments
)

SELECT
    c.portfolio_id,
    c.source_system,
    c.loan_id,
    c.payment_date,
    c.payment_source,
    a.acquisition_date,
    c.payment_date >= a.acquisition_date AS is_post_acquisition,
    c.payment_date IS NULL AS missing_payment_date_flag,
    SUM(c.amount) AS total_collections
FROM combined AS c
LEFT JOIN acquisition AS a
    ON a.portfolio_id = c.portfolio_id
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
ORDER BY 1, 3, 4 NULLS LAST;
