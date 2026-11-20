-- ============================================================================
-- batch_impact_matrix — one row per PAM batch, one column per known problem,
-- so a reader can see at a glance which issues touch which book and by how
-- much. Built for escalation to Intrum; see work/intrum-escalations.md.
-- GRAIN: one row per PAM COMBINED_REF. All 14 batches appear, including the
-- three with no CAT money — a batch with nothing in CAT is a finding, not a
-- row to drop.
-- ============================================================================
--   Terminal : mise run sql -- work/benchmark/batch_impact_matrix.sql
--   ⚠ accounts.sql and payments.sql moved 2026-09-11 to
--     work/project-elsa-benchmark/. Bare mentions below mean there.
--
-- WHAT EACH FLAG MEANS, AND WHICH DIRECTION IT PUSHES A COMPARISON.
--   NO_CAT_CASES     PAM reports money for a batch CAT has no loans for.
--                    Nothing to reconcile at all. Feed gap.
--   BATCH_DISPUTE    The batch's loans exist in CAT but their newest version
--                    names a DIFFERENT in-scope batch, so PAM bills the money
--                    here and CAT bills the loans elsewhere.
--   LAG_6M           PAM reports months CAT's extract cannot see (CAT ends
--                    2026-01-14, PAM runs to 2026-07). → CAT reads UNDER.
--                    Excluded from MATCH_RATIO on both sides; LAG_6M_EUR is
--                    what a naive whole-against-whole comparison would blame
--                    on the servicer.
--                    ⚠ IT IS SEVEN PAM MONTHS, NOT SIX. The window closes at
--                    the last COMPLETE CAT month, December 2025, because CAT's
--                    January is a half month. So the column sums 2026-01 to
--                    2026-07. "Six months behind" describes the extract; the
--                    column excludes seven reporting months.
--                    ⚠ THE COLUMN IS PAM-ONLY AND MEASURES RUN-OFF, NOT A
--                    FAULT. Its spread across batches looks alarming — 72% of
--                    the EUR 1,946,151.11 sits on the two 2016 books — but it
--                    is only telling you which books still collect. Checked
--                    2026-09-10 against each batch's trailing twelve months to
--                    the window close: every batch lands between 0.24x and
--                    0.74x of a year's collections, clustered near 0.5x, which
--                    is what seven months of an even run rate should look
--                    like. Nothing about the lag is batch-specific.
--                    ⚠ A BATCH WITH NO CAT LOANS CAN STILL SHOW LAG. It does
--                    not need CAT data to have PAM months after the cut.
--                    PT15018A040000 collected in 5 of those 7 months while CAT
--                    holds zero loans for it — which makes it a live book, not
--                    a dormant one, and sharpens the question in NO_CAT_MONEY.
--   UNDATED          CAT payments with no transaction date in ANY version.
--                    Real money that cannot be placed in a month, so it
--                    cannot enter MATCH_RATIO. → CAT reads UNDER.
--   PRE_CAPEX        CAT payments dated before the batch was bought. PAM's
--                    lifetime starts at the capex month so it structurally
--                    cannot hold them. → CAT would read OVER; excluded here.
--   WIPED_REF        Loans whose newest CAT version has a NULL
--                    LONG_PORTFOLIO_ID and blank seller. This file bills
--                    their payments to the last version that named a batch.
--                    WIPED_REF_EUR is the money resting on that workaround.
--   SOLD_ON          Loans whose newest CAT version names PT24004B000000,
--                    seller "INTRUM INVESTMENT SWITZER". Assumed an onward
--                    sale and out of scope.
--   AMOUNTLESS_LOANS Loans carrying a row that passes Intrum's payment filter
--                    with a NULL amount and NULL currency. Money unaffected;
--                    a payment COUNT from this feed is overstated by them.
--
-- ⚠ READ MATCH_RATIO WITH RESIDUAL_AFTER_UNDATED, NEVER ALONE. The ratio is
-- already period-matched — same months both sides, pre-capex cash excluded,
-- window closed at the last COMPLETE CAT month — so LAG_6M cannot flatter or
-- depress it. What the ratio does NOT credit is UNDATED_EUR, real money PAM
-- has already counted in some month, and that is the whole reason the
-- pre-2010 books look 3-11% short on MATCH_RATIO while their true residual is
-- under 1.3%. Quote RESIDUAL_AFTER_UNDATED as the unexplained figure, and
-- never quote MATCH_RATIO on a pre-2010 batch without it.
--
-- ⚠ THIS FILE IS CROSS-VALIDATED AGAINST pam_cat_match.sql, which was built
-- independently (2026-09-10). Summing RESIDUAL_AFTER_UNDATED reproduces that
-- file's measured figures to the cent: the nine pre-2010 batches total
-- -626,001.74 in a range of -0.09% to -1.23%, and the two 2016 batches total
-- +712,729.00. Two different queries agreeing on a fourteen-batch breakdown
-- is the reason to trust either.
--
-- ⚠ THREE BATCHES HAVE NO CAT MONEY AT ALL, not two. accounts.sql reports
-- "12 of 14" on a loan count, which hides PT070040000000: it HAS two loans in
-- CAT and neither has ever paid, while PAM reports EUR 340,000.00 against the
-- batch. On money rather than loans the tally is 11 of 14, and the three
-- unreconcilable batches carry EUR 1,130,420.97 of PAM collections between
-- them (PT06014B010000 660,000.00, PT070040000000 340,000.00,
-- PT15018A040000 130,420.97).
--
-- ⚠ AMOUNT-LESS PAYMENT ROWS ARE ON EVERY BATCH, not just PT050030000000 as
-- payments.sql used to say. 43,658 loans across all 12 batches carry a row
-- that passes Intrum's payment filter with a NULL amount: PT050030000000
-- 11,418 is only the largest. Money is unaffected; payment COUNTS are not.
--
-- ⚠ THE ONE BATCH THAT DOES NOT RECONCILE is PT15018G000000, over by ~EUR
-- 436k before undated cash and after every other correction above, and it is
-- also the only batch with a material WIPED_REF count. That is the leading
-- hypothesis and it is untested: if PAM has stopped reporting even a small
-- share of the wiped cohort's collections, that is the overage. The second
-- batch over, PT16023C000000, is already explained — its excess is
-- post-capex but pre-registration cash, so its PRE_CAPEX column reads 0.00
-- and only the post-registration cut in pam_cat_match.sql resolves it.
--
-- ⚠ THE DEDUPE ORDER HERE ADMITS AMOUNT-LESS ROWS ON PURPOSE, unlike
-- payments.sql. Ranking puts NULL amounts last, so a transaction that has any
-- real version still resolves to that version and the money is identical to
-- payments.sql; a transaction whose every version is amount-less survives with
-- a NULL amount, which is the only way to count them in the same single pass.
-- Money sums filter them back out. Do not copy this CTE into a money query.
--
-- ⚠ COST. One pass over the transaction feed with no date bound: about 9
-- minutes on the shared X-Small. Guards are those of payments.sql and
-- accounts.sql — one PAM file, PMODE_NAME='Real', no ownership-change rows,
-- CASES and TRANSACTIONS deduped to latest version, CASE_ID pinned to one
-- source system, payments only, AMOUNT negated, dates recovered across
-- versions.
--
-- ⚠ NOTHING MAY FOLLOW THE FINAL SEMICOLON, not even a comment.
-- ============================================================================

set country       = 'PT';
set seller        = 'MILLENNIUM';
set source_system = '4050';
set raw_prefix    = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
set sold_on_ref   = 'PT24004B000000';


with newest_pam_file as (
    select max(_file_path) as file_path
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path like '%/pam.pam.pam.2%'
),

pam_rows as (
    select
        p.combined_ref,
        p.capex_date_m::date      as capex_month,
        p.period_start_date::date as reporting_month,
        p.colltotal               as collections
    from RAW.HYPERION_INTRUM_PAM.PAM as p
    cross join newest_pam_file as nf
    where p._file_path = nf.file_path
      and p.pmode_name = 'Real'
      and coalesce(p.is_ownership_change, 0) = 0
      and p.countrycode like $country
      and upper(p.seller_name) like upper($seller)
      and p.period_start_date::date < date_trunc('month', to_timestamp_ntz(
              parse_json(p._file_metadata):extract_ts::string, 'YYYYMMDDTHH24MISS'))::date
),

batches as (
    select combined_ref, max(capex_month) as capex_month
    from pam_rows
    group by combined_ref
),

-- The case list exactly as accounts.sql builds it: batch filter BEFORE the
-- qualify, so a loan that has since left the scope keeps its last in-scope
-- batch rather than vanishing.
cases as (
    select
        c.long_portfolio_id       as portfolio_ref,
        c.case_id,
        c.registration_date::date as registration_date
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'
      and c.long_portfolio_id in (select combined_ref from batches)
      and c.case_id not like '%-%'
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

-- The same loans' newest version with NO batch filter, which is the only way
-- to see that a loan has been wiped or sold on.
true_latest as (
    select
        c.case_id,
        c.long_portfolio_id      as latest_ref,
        c.portfolio_sellers_name as latest_seller
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'
      and c.case_id in (select case_id from cases)
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

attribution as (
    select
        c.portfolio_ref,
        count(*)                                                       as loans,
        count(case when t.latest_ref is null then 1 end)               as wiped_ref_loans,
        count(case when t.latest_ref = $sold_on_ref then 1 end)        as sold_on_loans,
        count(case when t.latest_ref is not null
                    and t.latest_ref <> c.portfolio_ref
                    and t.latest_ref <> $sold_on_ref then 1 end)       as other_ref_loans
    from cases as c
    inner join true_latest as t on t.case_id = c.case_id
    group by c.portfolio_ref
),

-- One row per transaction. NULL amounts rank last (see the header warning), so
-- money matches payments.sql while amount-less transactions stay countable.
txns as (
    select
        t.case_id,
        max(t.transaction_date::date) over (
            partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        )                         as payment_date,
        -t.amount::decimal(38, 2) as amount
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
    where t._file_path like $raw_prefix || $source_system || '.transactions.%'
      and t.case_id in (select case_id from cases)
      and t.payment_cost_ind = 'P'
      and coalesce(t.booking_ind, 'N') != 'Y'
    qualify row_number() over (
        partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        order by iff(t.amount is null, 1, 0) asc,
                 coalesce(t.record_updated, t.update_ts)::timestamp desc nulls last
    ) = 1
),

window_end as (
    select dateadd(day, -1, date_trunc('month', max(payment_date)))::date as last_complete_day
    from txns
    where amount is not null
),

cat as (
    select
        c.portfolio_ref,
        sum(case when x.amount is not null
                  and x.payment_date >= b.capex_month
                  and x.payment_date <= w.last_complete_day
                 then x.amount else 0 end)                             as cat_matched,
        sum(case when x.amount is not null and x.payment_date is null
                 then x.amount else 0 end)                             as cat_undated,
        sum(case when x.amount is not null and x.payment_date < b.capex_month
                 then x.amount else 0 end)                             as cat_pre_capex,
        count(distinct case when x.amount is null then x.case_id end)   as amountless_loans,
        -- money resting on the wiped-reference workaround
        sum(case when t.latest_ref is null
                  and x.amount is not null
                  and x.payment_date >= b.capex_month
                  and x.payment_date <= w.last_complete_day
                 then x.amount else 0 end)                             as wiped_ref_eur
    from txns as x
    inner join cases       as c on c.case_id = x.case_id
    inner join true_latest as t on t.case_id = x.case_id
    inner join batches     as b on b.combined_ref = c.portfolio_ref
    cross join window_end  as w
    group by c.portfolio_ref
),

pam as (
    select
        pr.combined_ref,
        sum(pr.collections)                                             as pam_lifetime,
        sum(case when pr.reporting_month <= date_trunc('month', w.last_complete_day)
                 then pr.collections else 0 end)                        as pam_matched,
        sum(case when pr.reporting_month >  date_trunc('month', w.last_complete_day)
                 then pr.collections else 0 end)                        as lag_6m_eur
    from pam_rows as pr
    cross join window_end as w
    group by pr.combined_ref
)

select
    b.combined_ref                                    as batch,
    b.capex_month,
    coalesce(a.loans, 0)                              as loans_in_cat,
    coalesce(m.pam_lifetime, 0)                       as pam_lifetime,

    -- ---- the like-for-like comparison and what is left over ---------------
    coalesce(c.cat_matched, 0)                        as cat_matched,
    coalesce(m.pam_matched, 0)                        as pam_matched,
    div0(coalesce(c.cat_matched, 0),
         nullif(coalesce(m.pam_matched, 0), 0))       as match_ratio,
    -- Two residuals, because they answer different questions. The first is
    -- what MATCH_RATIO measures. The second credits back the undated cash,
    -- which is real money PAM has already counted in some month, and is the
    -- one to quote as "unexplained".
    coalesce(c.cat_matched, 0)
        - coalesce(m.pam_matched, 0)                  as residual_before_undated,
    coalesce(c.cat_matched, 0) + coalesce(c.cat_undated, 0)
        - coalesce(m.pam_matched, 0)                  as residual_after_undated,
    div0(coalesce(c.cat_matched, 0) + coalesce(c.cat_undated, 0)
             - coalesce(m.pam_matched, 0),
         nullif(coalesce(m.pam_matched, 0), 0))       as residual_after_undated_pct,

    -- ---- one pair of columns per issue: does it bite, and by how much -----
    iff(coalesce(a.loans, 0) = 0
        and coalesce(m.pam_lifetime, 0) > 0, 'Y', '-') as no_cat_cases,
    -- Wider than NO_CAT_CASES on purpose: PT070040000000 HAS two loans in CAT
    -- and no payments on either, so a loans-based flag alone would miss it
    -- while PAM reports EUR 340,000.00 against the batch.
    iff(coalesce(c.cat_matched, 0) = 0
        and coalesce(m.pam_lifetime, 0) > 0, 'Y', '-') as no_cat_money,
    iff(coalesce(c.cat_matched, 0) = 0
        and coalesce(m.pam_lifetime, 0) > 0,
        coalesce(m.pam_lifetime, 0), 0)                as no_cat_money_eur,

    iff(coalesce(a.other_ref_loans, 0) > 0
        or (coalesce(a.loans, 0) = 0
            and coalesce(m.pam_lifetime, 0) > 0
            and b.combined_ref = 'PT15018A040000'), 'Y', '-') as batch_dispute,

    iff(coalesce(m.lag_6m_eur, 0) > 0, 'Y', '-')      as lag_6m,
    coalesce(m.lag_6m_eur, 0)                         as lag_6m_eur,

    iff(coalesce(c.cat_undated, 0) > 0, 'Y', '-')     as undated,
    coalesce(c.cat_undated, 0)                        as undated_eur,

    iff(coalesce(c.cat_pre_capex, 0) > 0, 'Y', '-')   as pre_capex,
    coalesce(c.cat_pre_capex, 0)                      as pre_capex_eur,

    iff(coalesce(a.wiped_ref_loans, 0) > 0, 'Y', '-') as wiped_ref,
    coalesce(a.wiped_ref_loans, 0)                    as wiped_ref_loans,
    coalesce(c.wiped_ref_eur, 0)                      as wiped_ref_eur,

    iff(coalesce(a.sold_on_loans, 0) > 0, 'Y', '-')   as sold_on,
    coalesce(a.sold_on_loans, 0)                      as sold_on_loans,

    iff(coalesce(c.amountless_loans, 0) > 0, 'Y', '-') as amountless,
    coalesce(c.amountless_loans, 0)                   as amountless_loans
from batches as b
left join attribution as a on a.portfolio_ref = b.combined_ref
left join cat         as c on c.portfolio_ref = b.combined_ref
left join pam         as m on m.combined_ref  = b.combined_ref
order by b.capex_month, b.combined_ref;
