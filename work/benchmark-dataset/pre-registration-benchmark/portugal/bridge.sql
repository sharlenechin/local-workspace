-- ============================================================================
-- PT asset-index -> prod case bridge. ONE ROW PER PROD CASE, for the 12
-- Portuguese deals that have asset-index tapes in this folder.
--
--   RUN    mise run sql -- work/benchmark-dataset/pre-registration-benchmark/portugal/bridge.sql
--   GRAIN  one row per prod case. 118,177 rows, verified unique on
--          intrum_case_number. Measured 2026-10-05.
--   WHY    OVERVIEW.md. The tapes live in Excel, not Snowflake, so this
--          delivers the WAREHOUSE half of the bridge: the seller's own loan
--          reference (client_ref_1) beside the prod keys. Join your tape to
--          CLIENT_REF_1 and you are in DIM_CASE.
--
-- ⚠⚠ CLIENT_REF_1 IS THE ONLY LINK TO THE SELLER'S WORLD. Prod DIM_CASE.CASE_ID
--    is md5('intrum' || case_bk) -- a hash, readable by nothing. CASE_BK is
--    '4050-' || Intrum's own case number. Neither carries the seller reference
--    the tapes are keyed on. CLIENT_REF_1 survives only in RAW, so this query
--    must read RAW and cannot be replaced by a modelled table.
--
-- ⚠⚠ THE PT FEED'S FULL LOAD IS 2026-01-14, SPLIT ACROSS THREE FILES, AND THE
--    NEWEST EXTRACT IS A DELTA. cat.4050.cases.20260115T071911 holds 1,178 rows;
--    picking "the latest file" returns those 1,178 and nothing else, with no
--    error. The 20260114 prefix below is the full load (85,386,136 change
--    rows). _file_path pruning is the only lever that makes this affordable.
--
-- ⚠⚠ RAW CAT IS CHANGE HISTORY, NOT A CASE LIST. 85.4m rows carry 118,177
--    cases -- roughly 720 versions each. The QUALIFY below is load-bearing;
--    without it every downstream count multiplies by that factor.
--
-- ⚠ A CASE'S DEAL IS NOT STABLE. 8,190 cases carry more than one batch code
--   across their history, and 498 sit under two different DEALS at different
--   points. This returns each case's LATEST state, so a case counted under
--   PT19013 by an earlier extract may appear under another deal here. Deal
--   totals therefore shift slightly depending on which record you take --
--   PT19013 is 2,256 cases on a DISTINCT and 1,890 at latest state.
--
-- ⚠ client_ref_1 is populated on all 118,177 cases -- there is no NULL to
--   guard. 24 cases do not reach DIM_CASE (19 on PT19007, 5 on PT19013); they
--   are kept with a NULL case_sk rather than dropped.
--
-- ⚠ DIM_CASE IS AN SCD. Without IS_CURRENT_FLAG this returns one row per
--   historical version and every sum multiplies.
-- ============================================================================

SET cat_full_load = '%cat.4050.cases.20260114%';

WITH cat_cases AS (
    -- ⚠ ONE ROW PER CASE, TAKEN AT ITS LATEST CHANGE RECORD. A plain DISTINCT
    --   does NOT give that: 8,190 cases carry more than one long_portfolio_id
    --   across their history, so DISTINCT returns 126,367 rows for 118,177
    --   cases. QUALIFY collapses to the current state of each case.
    SELECT
        LEFT(c.long_portfolio_id, 7) AS deal,
        c.long_portfolio_id          AS batch_bk,
        c.case_id,
        c.client_ref_1               AS seller_loan_reference,
        c.portfolio_sellers_name     AS seller_name
    FROM raw.hyperion_intrum_cat.cases AS c
    WHERE c._file_path LIKE $cat_full_load
      AND LEFT(c.long_portfolio_id, 7) IN (
          'PT15014', 'PT15016', 'PT15018', 'PT15020', 'PT16023', 'PT18019',
          'PT19007', 'PT19013', 'PT20006', 'PT20008', 'PT20014', 'PT21004')
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY c.case_id
        ORDER BY COALESCE(c.record_updated, c.update_ts) DESC
    ) = 1
)

SELECT
    cc.deal,
    cc.batch_bk,
    cc.seller_name,
    -- The tape key. Zero-padded to 19 digits on the Wizink and Barclays books,
    -- plain on Millennium and Oney. Strip leading zeros on BOTH sides before
    -- joining -- the tapes are inconsistent about the padding.
    cc.seller_loan_reference,
    cc.case_id                       AS intrum_case_number,
    dc.case_bk,
    dc.case_sk,
    dc.status_code,
    dc.registration_date,
    dc.default_date
FROM cat_cases AS cc
LEFT JOIN prod.npl_common.dim_case AS dc
       ON dc.case_bk = '4050-' || cc.case_id
      AND dc.is_current_flag = TRUE
ORDER BY cc.deal, cc.seller_loan_reference;
