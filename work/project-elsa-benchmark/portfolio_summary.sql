-- ============================================================================
-- portfolio_summary — one row per PAM batch, the acquisition side of the book
--
--   RUN      mise run sql -- work/project-elsa-benchmark/portfolio_summary.sql
--            datalake.q("work/project-elsa-benchmark/portfolio_summary")
--   GRAIN    one row per COMBINED_REF (batch). 14 rows.
--   PAIRS    accounts.sql / payments.sql on PORTFOLIO_ID = COMBINED_REF.
--            ⚠ Those two return 11 batches, not 14 — see EXCLUDED below.
--   RUNTIME  ~5s. PAM is small.
--   SOURCE   RAW.HYPERION_INTRUM_PAM.PAM, newest whole delivery only.
--
-- All figures measured 2026-09-14.
-- ============================================================================
-- RETURNS  14 rows × 11 columns. This is what INTRUM SAYS IT BOUGHT — the
--          deal-level view, not a roll-up of our loan-level data. The two do
--          not agree on every batch and are not meant to; accounts.sql's
--          CROSS-CHECKS section carries the per-batch comparison.
--
--   PORTFOLIO_ID            COMBINED_REF. Joins to accounts.sql PORTFOLIO_ID.
--   CAPEX_DATE / _YEAR      when Intrum bought the batch (CAPEX_DATE_M).
--   CAPEX_AMOUNT            RP_PURCHASE_PRICE, what was paid.
--   ACQ_BALANCE             ACQUISITIONPRINCIPAL, principal acquired.
--   PRICE_PCT               CAPEX_AMOUNT / ACQ_BALANCE × 100. Cents on the euro.
--   ACQ_ACCOUNTS            ACQCASES — cases at acquisition.
--   ACQ_DEBTORS             ACQDEBTORS — debtors at acquisition.
--   AVG_DEBT_AGE_YEARS      AVERAGE_DEBT_AGE, PAM's own figure, in YEARS.
--   PAM_COLLECTIONS         lifetime COLLTOTAL, actuals.
--   PAM_LAST_COLLECTION_M   last month carrying cash — the actuals horizon.
--
-- ============================================================================
-- READ FIRST
-- ============================================================================
-- 1. ACQ_ACCOUNTS IS NOT OUR LOAN COUNT AND MUST NOT BE COMPARED TO IT.
--    ACQCASES counts cases as at acquisition; accounts.sql counts loans still
--    in the CAT feed today, after its own guards. PT050030000000 reads 42,011
--    here against 28,312 there. Neither is wrong — they count different things
--    at different times. Report them side by side, never as a variance.
--
-- 2. CAPEX_AMOUNT IS POSTED ONCE, COLLECTIONS ARE MONTHLY. PAM holds one row
--    per batch per month, out to 2039. Verified single-valued per batch and
--    taken with max(): CAPEX_DATE_M, ACQUISITIONPRINCIPAL, ACQCASES,
--    ACQDEBTORS, AVERAGE_DEBT_AGE. Taken with sum(): RP_PURCHASE_PRICE (lands
--    entirely in the capex month) and COLLTOTAL.
--
-- 3. THE FUTURE MONTHS ARE ZERO, NOT FORECAST. PMODE_NAME has exactly one
--    value in this scope, 'Real'. Rows run to 2039-01 but carry no cash after
--    2026-08, so summing COLLTOTAL over every row returns actuals and nothing
--    else. PAM_LAST_COLLECTION_M is returned so that stays visible rather than
--    assumed — if a future delivery starts posting forecast into 'Real', that
--    column moves and the guard has to be revisited.
--
-- 4. PAM RESTATES. These are the figures in the NEWEST whole delivery. An
--    earlier delivery gives different numbers for the same batch and month;
--    that is PAM working as designed, not an error. Never mix deliveries.
--
-- ============================================================================
-- EXCLUDED — the three batches accounts.sql and payments.sql drop
-- ============================================================================
-- All 14 are returned HERE on purpose, so the summary can state why three of
-- them carry no loans rather than leaving them off and looking complete.
--   PT06014B010000  no cases in CAT under any source system. A feed gap.
--   PT070040000000  2 loans holding EUR 2.00 of capital each. Never paid.
--   PT15018A040000  its 84 cases resolve to PT16023C000000, so it was never in
--                   the output. 15.1m of acquired principal with no loans.
-- ⚠ TWO OF THE THREE POST AN ACCOUNTING ENTRY, NOT CASH. PT06014B010000 and
-- PT070040000000 each post ONE month equal to their own ACQUISITIONPRINCIPAL
-- to the cent, in the capex month. No other batch, in ~2,500 collecting
-- months, ever does. EUR 1,000,000.00 across the two. Do not read their
-- PAM_COLLECTIONS as money recovered. See work/intrum-escalations.md.
--
-- ============================================================================
-- GUARDS
-- ============================================================================
-- G1 NEWEST WHOLE DELIVERY ONLY. `_file_path like '%/pam.pam.pam.2%'` selects
--    whole-file deliveries; the max of those is the current one. Without the
--    pattern the max can land on a forecast file, which has a different shape.
-- G2 pmode_name = 'Real' and is_ownership_change = 0, matching accounts.sql's
--    `batches` CTE exactly. Change one and you must change both, or the batch
--    list here stops agreeing with the batch list there.
-- G3 SELLER MATCH IS CASE-INSENSITIVE — both casings exist in PAM.
--
-- ⚠ NOTHING MAY FOLLOW THE FINAL SEMICOLON, not even a comment: run_sql.py
-- splits on ';' and a trailing comment-only chunk fails.
-- ============================================================================

set country   = 'PT';
set sellers   = 'MILLENNIUM|WIZINK';
set deal_type = 'One-off';   -- G4

with latest_delivery as (
    select *
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path = (
              select max(_file_path)
              from RAW.HYPERION_INTRUM_PAM.PAM
              where _file_path like '%/pam.pam.pam.2%'          -- G1
          )
      and pmode_name = 'Real'                                   -- G2
      and coalesce(is_ownership_change, 0) = 0                  -- G2
      and countrycode like $country
      and regexp_like(upper(seller_name), '.*(' || $sellers || ').*')   -- G3
      and deal_type_desc = $deal_type                           -- G4
)

select
    combined_ref                                        as portfolio_id,
    iff(upper(max(seller_name)) like '%WIZINK%',
        'Wizink', 'Millennium')                         as seller_name,
    max(capex_date_m)::date                             as capex_date,
    year(max(capex_date_m)::date)                       as capex_year,
    -- Posted once, in the capex month (N2).
    sum(rp_purchase_price)                              as capex_amount,
    max(acquisitionprincipal)                           as acq_balance,
    -- Cents on the euro. Guarded so a zero-principal batch returns null
    -- rather than failing the whole statement.
    iff(max(acquisitionprincipal) = 0, null,
        sum(rp_purchase_price) / max(acquisitionprincipal) * 100)
                                                        as price_pct,
    max(acqcases)                                       as acq_accounts,   -- ⚠ not our loan count, N1
    max(acqdebtors)                                     as acq_debtors,
    sum(colltotal)                                      as pam_collections,
    -- PAM cut at the CAT extract month, so a CAT-vs-PAM ratio compares the
    -- same window. Without this the ratio is not like-for-like (N4).
    sum(iff(period_start_date::date <= '2026-01-31', colltotal, 0))
                                                        as pam_collections_to_cat_cut,
    -- The actuals horizon, returned rather than assumed (N3).
    max(case when colltotal <> 0 then period_start_date end)::date
                                                        as pam_last_collection_m
from latest_delivery
group by combined_ref
order by seller_name, capex_date, combined_ref;
