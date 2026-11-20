-- ============================================================================
-- ref_borrower — REFERENCE: one row per customer behind the loans we hold.
-- GRAIN: one row per BORROWER_ID.
-- ============================================================================
-- The "who" sheet. One row per borrower, with the loans they are attached to
-- rolled up: how many, in which portfolios, total balance, total collected.
--
--   Terminal : mise run sql -- work/servicing/prod/ref_borrower.sql
--   Notebook : datalake.q("servicing/prod/ref_borrower")
--
-- ---------------------------------------------------------------------------
-- GRAIN: one row per BORROWER_ID. Not per BORROWER_SK — see below.
--
-- ⚠ BORROWER_SK IS VERSIONED, BORROWER_ID IS NOT.
-- DIM_BORROWER holds 29,924,331 rows for 17,073,052 real borrowers (SCD2,
-- IS_CURRENT marks the live version). BRG_CASE_BORROWER carries the
-- *versioned* BORROWER_SK, so joining the bridge and counting BORROWER_SK
-- inflates the customer count by ~75%. This query joins on BORROWER_SK and
-- groups by BORROWER_ID, which is both complete and correctly counted.
--
-- ⚠ THE CASE↔BORROWER RELATIONSHIP IS MANY-TO-MANY IN BOTH DIRECTIONS.
-- BRG_CASE_BORROWER is 229,335,306 rows over 143,631,793 case versions and
-- 29,680,110 borrower versions. Of the 22.5M current loans, 14.3M have one
-- borrower and 8.2M have two or more (up to 12+). So:
--   * joining borrowers onto loans multiplies the loan count by ~1.36
--   * a borrower's TOTAL_BALANCE below is the sum of the FULL balance of
--     every loan they are on, NOT their share of it. Two borrowers on one
--     EUR 100k loan each show EUR 100k. Summing TOTAL_BALANCE across
--     borrowers therefore DOUBLE COUNTS and will exceed the portfolio.
--     Use ref_loan.sql for any balance total that must foot.
-- ---------------------------------------------------------------------------
-- KNOWN NULLS across all 29.9M borrower rows — measured:
--   VAT                  99.55% null  -- unusable as an identity key
--   CREDIT_RATING        84.81% null
--   GENDER               61.62% null
--   COUNTRY_ID           26.53% null  -- prefer the loan's COUNTRY_ID, which
--                                     -- is populated, for geography
--   LEGAL_EBA_TYPE        0.72% null  -- the one reliable segmentation:
--                                     -- individual vs corporate
--
-- There is no name, address, phone or email column in DIM_BORROWER at all —
-- so this is a pseudonymous reference sheet, not a contactable customer
-- list. If you need contact data for a servicing workflow, it is not in the
-- warehouse and that is a question for the data team.
--
-- ⚠ $ROW_LIMIT TRUNCATES SILENTLY — CHECK IT BEFORE YOU AGGREGATE.
-- The cap exists so an accidental '%' filter cannot pull tens of millions of
-- rows into pandas. But a truncated result still sums, averages and charts
-- perfectly happily, and the total is simply wrong. If the row count comes
-- back exactly equal to $row_limit, assume it was cut: narrow
-- $portfolio_filter, shorten the window, or raise the cap deliberately.
-- ============================================================================

set month_end        = '2026-07-31';
set portfolio_filter = 'LOK-DE24016-U01/2512';
set row_limit        = 50000;


with portfolio_scope as (
    select portfolio_sk, portfolio_bk
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter
),

book as (
    -- Loans on book at $month_end, in scope.
    select s.case_sk, s.portfolio_sk, s.currency_id, s.country_id,
           s.outstanding_total
    from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY as s
    inner join portfolio_scope as p on p.portfolio_sk = s.portfolio_sk
    where s.date_day = $month_end::date
),

case_collections as (
    -- Lifetime collections per loan, so the borrower roll-up below does not
    -- have to touch the 134M-row collection fact a second time.
    -- Upper bound guards the 841 future-dated rows (up to the year 4570).
    select c.case_sk, sum(c.amount) as collected_lifetime,
           max(c.collection_date) as last_collection_date
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join book on book.case_sk = c.case_sk
    where c.collection_date <= $month_end::date
    group by 1
),

borrower_loans as (
    -- Bridge, restricted to loans in scope. Joined on the versioned
    -- BORROWER_SK, carrying the durable BORROWER_ID up for grouping.
    select
        bo.borrower_id,
        b.case_sk,
        book.portfolio_sk,
        book.country_id      as loan_country_id,
        book.currency_id,
        book.outstanding_total,
        cc.collected_lifetime,
        cc.last_collection_date
    from PROD.NPL_COMMON.BRG_CASE_BORROWER as b
    inner join book                            on book.case_sk = b.case_sk
    inner join PROD.NPL_COMMON.DIM_BORROWER as bo on bo.borrower_sk = b.borrower_sk
    left  join case_collections as cc          on cc.case_sk = b.case_sk
),

borrower_current as (
    -- One attribute row per borrower: the live SCD2 version.
    select borrower_id, legal_eba_type, original_legal_type, credit_rating,
           credit_rating_at_case_opening, gender, country_id, debtor_number,
           vat, record_update_date
    from PROD.NPL_COMMON.DIM_BORROWER
    where is_current
      and borrower_id in (select borrower_id from borrower_loans)
    qualify row_number() over (
        partition by borrower_id order by record_update_date desc nulls last
    ) = 1
)

select
    bl.borrower_id,

    -- ---- who they are (see null rates in the header) ---------------------
    bc.legal_eba_type,                          -- individual vs corporate;
                                                -- the only near-complete field
    bc.original_legal_type,
    bc.gender,                                  -- 62% null
    bc.credit_rating,                           -- 85% null
    bc.credit_rating_at_case_opening,
    bc.country_id            as borrower_country_id,   -- 27% null
    max(bl.loan_country_id)  as loan_country_id,       -- populated; prefer this
    bc.debtor_number,
    bc.vat,                                     -- 99.6% null
    bc.record_update_date,

    -- ---- what they owe us -----------------------------------------------
    count(distinct bl.case_sk)          as n_loans,
    count(distinct bl.portfolio_sk)     as n_portfolios,
    listagg(distinct ps.portfolio_bk, ', ')
        within group (order by ps.portfolio_bk) as portfolios,
    count(distinct bl.currency_id)      as n_currencies,
    listagg(distinct bl.currency_id, ',')
        within group (order by bl.currency_id)  as currencies,

    -- ⚠ FULL loan balance, not this borrower's share. Do not sum across
    -- borrowers — joint loans are counted once per borrower. See header.
    sum(bl.outstanding_total)           as total_balance_unapportioned,
    max(bl.outstanding_total)           as largest_loan_balance,
    sum(coalesce(bl.collected_lifetime, 0))
                                        as collected_lifetime_unapportioned,
    max(bl.last_collection_date)        as last_collection_date,
    datediff(month, max(bl.last_collection_date), $month_end::date)
                                        as months_since_last_payment,

    -- A borrower on several loans is worth handling as one relationship.
    iff(count(distinct bl.case_sk) > 1, true, false) as is_multi_loan,
    iff(max(bl.last_collection_date) is null, true, false) as never_paid

from borrower_loans as bl
left join borrower_current as bc on bc.borrower_id = bl.borrower_id
left join portfolio_scope  as ps on ps.portfolio_sk = bl.portfolio_sk
group by
    bl.borrower_id, bc.legal_eba_type, bc.original_legal_type, bc.gender,
    bc.credit_rating, bc.credit_rating_at_case_opening, bc.country_id,
    bc.debtor_number, bc.vat, bc.record_update_date
order by total_balance_unapportioned desc nulls last
limit $row_limit
