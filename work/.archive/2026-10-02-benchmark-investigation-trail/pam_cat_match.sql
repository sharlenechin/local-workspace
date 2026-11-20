-- ============================================================================
-- pam_cat_match — the like-for-like reconciliation of CAT payments to PAM
-- collections, with every source of difference broken out as its own column.
-- GRAIN: one row per batch (PAM COMBINED_REF).
-- ============================================================================
--   Terminal : mise run sql -- work/benchmark/pam_cat_match.sql
--   ⚠ accounts.sql and payments.sql moved 2026-09-11 to
--     work/project-elsa-benchmark/. Bare mentions below mean there.
--
-- WHY THIS FILE EXISTS. Compared whole-against-whole, CAT is 99.88% of PAM,
-- and that number is meaningless — it is two large opposite errors cancelling.
-- Cut both to the same months and CAT is 100.92%. Neither figure tells you
-- anything until the four real differences are separated, which is what the
-- columns below do. Every one was measured 2026-09-10.
--
-- THE FOUR DIFFERENCES, AND WHICH DIRECTION EACH PUSHES.
--
--   1. PAM'S LIFETIME STARTS AT CAPEX — CAT'S DOES NOT.  → CAT OVER
--      PAM's first reported month IS the capex month, so it structurally
--      cannot hold a payment from before the purchase. CAT carries the
--      servicer's earlier history. This is the ENTIRE reason the two 2016
--      batches read over 100%, and it is not an error in either source:
--        PT15018G000000  2015: CAT 1,054,484.34 vs PAM 0.00 (capex 2016-03)
--        PT15018G000000  2016: CAT 5,616,413.57 vs PAM 4,727,287.04
--        PT16023C000000  2016: CAT   322,912.24 vs PAM 0.00 (capex 2016-12)
--      Excluded from the match window below and reported as CAT_PRE_CAPEX.
--
--   2. THE CAT EXTRACT IS SIX MONTHS BEHIND PAM.  → CAT UNDER
--      CAT's last payment is 2026-01-14, its extract date. PAM's newest
--      delivery was extracted 2026-08 and reports actuals to 2026-07. So PAM
--      holds six months CAT cannot: EUR 1,653,076.48 across these batches.
--      Visible per batch in 2026: PT16023C000000 CAT 18,299.57 vs PAM
--      698,031.90; PT15018G000000 CAT 36,752.37 vs PAM 707,659.43.
--      The window therefore ENDS AT THE LAST COMPLETE CAT MONTH, not at the
--      extract date — January 2026 is a half month in CAT and would drag the
--      match down for no reason.
--
--   3. 3.1% OF CAT PAYMENTS HAVE NO DATE AT ALL.  → CAT UNDER, IN EVERY YEAR
--      16,551 payments across 6,090 loans, EUR 5,450,225.84. They cannot be
--      placed in a month, so they cannot enter a period-matched comparison.
--      This is why the pre-2010 years read consistently under: the undated
--      cash belongs to them. Reported as CAT_UNDATED and deliberately left
--      OUT of the matched figure — putting it in would flatter the match
--      while placing money in the wrong periods.
--
--   4. PAM RESTATES PAST MONTHS AS LATE CASH LANDS. → either way, small
--      The newest PAM file is the most complete, which is why it is the only
--      one read. Residual timing after 1-3 should be small and two-sided.
--
-- ⚠ HOW TO READ THE RESULT. MATCH_RATIO compares like with like:
-- CAT payments dated inside [capex month, last complete CAT month] against
-- PAM actuals for the same months. A batch near 100% reconciles. A batch
-- short by roughly its CAT_UNDATED share is explained. Anything left after
-- that is unexplained and worth raising — PT15018G000000 was ~EUR 362k over
-- even after allowing for pre-capex cash, and that is not yet understood.
--
-- MEASURED RESULT (2026-09-10, window 2005-06 .. 2025-12):
--     CAT matched          153,117,164.88
--     CAT undated            5,450,225.84   (cannot be placed in a month)
--     PAM matched          158,480,663.46
--     CAT matched+undated / PAM matched = 100.05%   (+86,727.26)
-- That 0.05% is a NET of two opposite residuals which happen to cancel, so
-- do not read it as "reconciled" without looking at both halves:
--     9 pre-2010 batches  -626,001.74  = -0.59% of PAM, EVERY ONE under
--                                        (range -0.09% to -1.23%)
--     2 x 2016 batches    +712,729.00  = +1.37% of PAM, BOTH over
--                                        (PT15018G000000 +1.30%,
--                                         PT16023C000000 +1.51%)
-- ⚠ THE OVER IS NOT A TIMING EFFECT, and this was the specific thing tested.
-- Pre-capex cash is already excluded (CAT_PRE_CAPEX), the window already ends
-- at the last complete CAT month, and extract lag pushes CAT DOWN not up. The
-- two 2016 batches are over after all three corrections and neither has any
-- undated cash to explain it. Unexplained as at 2026-09-10.
-- ⚠ THE BATCH-ATTRIBUTION HYPOTHESIS IS DEAD — TESTED 2026-09-10. It read:
-- PT15018A040000 has PAM collections and no CAT cases of its own, and it is a
-- sub-batch of the same Intrum portfolio as PT15018G000000 (both PT15018*),
-- so if CAT attributes its loans to the sibling, the sibling reads over by
-- roughly that amount. Measured: its 84 cases go to PT16023C000000, NOT to
-- PT15018G000000, and they carry only EUR 11,955.29 of in-window payments
-- against the batch's EUR 130,420.97 of PAM collections. So the hypothesis
-- explains NONE of PT15018G000000's excess, and at most 3.7% of
-- PT16023C000000's — which the post-registration cut below already resolves.
-- PT15018G000000's ~EUR 362k over is therefore still unexplained. Two more
-- causes were ruled out at the same time: the $source_system pin hides no
-- cases (4050 is the only system holding any of these batches), and
-- latest-version-wins drops none either, because the batch filter runs before
-- the qualify. See batch_attribution_audit.sql for both measurements.
-- ⚠ THE ONE CANDIDATE LEFT, UNTESTED: 2,173 of PT15018G000000's 17,943 loans
-- (12%) have a NULL LONG_PORTFOLIO_ID and a blank seller name in their newest
-- CAT version, and they carry EUR 6,831,847.76 of in-window payments. This
-- file bills all of it to PT15018G000000, on their last version that named a
-- batch. No other batch does this — closure alone does not cause it — so if
-- PAM has stopped reporting even 5% of that cohort's collections, that is the
-- overage. Test that before anything else.
-- The pre-2010 shortfall is a separate question: consistent direction, small,
-- and the likeliest cause is the NULL-ORIG_TR_ID collapse in the dedupe key,
-- which only ever drops rows. Also untested.
--
-- POST-REGISTRATION CUT (added 2026-09-10). POSTREG_RATIO repeats the match
-- with the lower bound set to each CASE's own REGISTRATION_DATE instead of the
-- batch capex month. Overall it barely moves the answer — 96.37% against
-- 96.62% before undated cash is credited — because registration and capex are
-- days apart on most batches. It matters on exactly two:
--     PT16023C000000  101.51% -> 99.75%   <- RESOLVED
--     PT050030000000   90.88% -> 90.37%
-- PT16023C000000 IS THE FINDING. Its 1.51% overage was EUR 322,493.00 of
-- payments made after the December 2016 purchase but before the cases were
-- registered a few weeks later. Removing them lands it at 99.75%, so PAM
-- evidently does NOT count pre-registration cash even when it falls after
-- capex. That is worth knowing: PAM's collection clock starts at case
-- registration, not at the capex month its lifetime starts from.
-- PT15018G000000 is UNCHANGED at 101.29% — its pre-registration cash is also
-- pre-capex, so the capex cut had already removed it. Still unexplained.
-- On a post-registration basis, with undated cash credited back:
--     9 pre-2010 batches  -0.65%    2 x 2016 batches  +0.75%
--     overall 99.81% (-306,404.04) against 100.05% on the capex cut
-- Both bases are defensible. Use the capex cut to ask "what could PAM
-- possibly report"; use the post-registration cut to ask "what came in while
-- Intrum was servicing the case". They differ by EUR 393,131.30.
--
-- ⚠ THE SIX-MONTH DELIVERY LAG IS NOT A RECONCILIATION PROBLEM. The window
-- closes at the last complete CAT month on BOTH sides, so the lag is excluded
-- from every ratio above and cannot explain any residual. It is a coverage
-- problem instead, and its size depends entirely on the question:
--     missing at loan level (Jan-Jul 2026)   1,946,151.11
--     = 1.20% of the 21-year lifetime        (immaterial for vintage work)
--     = 54% of calendar 2025 collections     (fatal for anything current)
-- The book is in run-off — 2023: 5,186,062.63, 2024: 4,340,821.85,
-- 2025: 3,584,454.52, falling ~17% a year — so the missing months are the
-- ones that carry the trend. Read anything recent from PAM, not from here.
--
-- ⚠ THE UNDATED CASH IS REAL MONEY. Do not treat MATCH_RATIO as a data
-- quality score and do not "fix" a batch by discarding CAT_UNDATED.
-- CAT_TOTAL_ALL is the book's collections; MATCH_RATIO is a period-matched
-- diagnostic, and they answer different questions.
--
-- Guards are those established in payments.sql and accounts.sql: one PAM
-- file, PMODE_NAME='Real', no ownership-change rows, PAM collapsed before
-- joining, CASES and TRANSACTIONS deduped to latest version, CASE_ID pinned
-- to one source system, payments only, AMOUNT negated, transaction date
-- recovered across versions.
--
-- ⚠ NOTHING MAY FOLLOW THE FINAL SEMICOLON, not even a comment.
-- ============================================================================

set country       = 'PT';
set seller        = 'MILLENNIUM';
set source_system = '4050';
set raw_prefix    = 'data-prod-data-raw-sftp-071269be/intrum/cat.';


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
    inner join newest_pam_file as nf
        on nf.file_path = p._file_path
    where p.pmode_name = 'Real'
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

cases as (
    select c.long_portfolio_id as combined_ref, c.case_id,
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

payments as (
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
      and t.amount is not null
    qualify row_number() over (
        partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        order by coalesce(t.record_updated, t.update_ts)::timestamp desc nulls last
    ) = 1
),

-- The window closes at the last COMPLETE month in the CAT feed, so a partial
-- final month cannot depress the match. Derived, never hardcoded.
window_end as (
    select dateadd(day, -1, date_trunc('month', max(payment_date)))::date as last_complete_day
    from payments
),

cat as (
    select
        c.combined_ref,
        sum(p.amount)                                                          as cat_total_all,
        sum(case when p.payment_date is null then p.amount else 0 end)         as cat_undated,
        sum(case when p.payment_date <  b.capex_month then p.amount else 0 end) as cat_pre_capex,
        sum(case when p.payment_date >  w.last_complete_day then p.amount else 0 end) as cat_after_window,
        sum(case when p.payment_date >= b.capex_month
                  and p.payment_date <= w.last_complete_day then p.amount else 0 end) as cat_matched,
        -- post-registration cut: measured against each CASE's own registration
        -- date, not the batch capex month. Different question, different number.
        sum(case when p.payment_date <  c.registration_date then p.amount else 0 end) as cat_pre_registration,
        sum(case when p.payment_date >= c.registration_date
                  and p.payment_date <= w.last_complete_day then p.amount else 0 end) as cat_postreg_matched,
        sum(case when c.registration_date is null then p.amount else 0 end)            as cat_no_reg_date
    from payments as p
    inner join cases   as c on c.case_id      = p.case_id
    inner join batches as b on b.combined_ref = c.combined_ref
    cross join window_end as w
    group by c.combined_ref
),

pam as (
    select
        pr.combined_ref,
        sum(pr.collections)                                                    as pam_total_all,
        sum(case when pr.reporting_month <= date_trunc('month', w.last_complete_day)
                 then pr.collections else 0 end)                               as pam_matched,
        sum(case when pr.reporting_month >  date_trunc('month', w.last_complete_day)
                 then pr.collections else 0 end)                               as pam_after_window,
        -- twelve complete months to the window close, to size the lag against
        -- a recent run rate rather than against a 21-year lifetime.
        sum(case when pr.reporting_month >  dateadd(month, -12, date_trunc('month', w.last_complete_day))
                  and pr.reporting_month <= date_trunc('month', w.last_complete_day)
                 then pr.collections else 0 end)                               as pam_trailing_12m
    from pam_rows as pr
    cross join window_end as w
    group by pr.combined_ref
)

select
    b.combined_ref                                as batch_id,
    b.capex_month,

    -- ---- the like-for-like pair ------------------------------------------
    coalesce(c.cat_matched, 0)                    as cat_matched,
    coalesce(m.pam_matched, 0)                    as pam_matched,
    coalesce(c.cat_matched, 0) - coalesce(m.pam_matched, 0)              as match_diff,
    div0(coalesce(c.cat_matched, 0), nullif(coalesce(m.pam_matched, 0), 0)) as match_ratio,

    -- ---- the same pair, cut at each case's own registration date ----------
    coalesce(c.cat_postreg_matched, 0)            as cat_postreg_matched,
    coalesce(c.cat_postreg_matched, 0) - coalesce(m.pam_matched, 0)      as postreg_diff,
    div0(coalesce(c.cat_postreg_matched, 0), nullif(coalesce(m.pam_matched, 0), 0)) as postreg_ratio,
    coalesce(c.cat_pre_registration, 0)           as cat_pre_registration,

    -- ---- what was excluded, and why --------------------------------------
    coalesce(c.cat_pre_capex, 0)                  as cat_pre_capex,     -- diff 1: CAT over
    coalesce(m.pam_after_window, 0)               as pam_after_window,  -- diff 2: CAT under
    coalesce(m.pam_trailing_12m, 0)               as pam_trailing_12m,
    div0(coalesce(m.pam_after_window, 0), nullif(coalesce(m.pam_trailing_12m, 0), 0)) as lag_vs_trailing_12m,
    coalesce(c.cat_undated, 0)                    as cat_undated,       -- diff 3: CAT under
    coalesce(c.cat_after_window, 0)               as cat_after_window,  -- partial final month

    -- ---- the unmatched totals, for reference ------------------------------
    coalesce(c.cat_total_all, 0)                  as cat_total_all,
    coalesce(m.pam_total_all, 0)                  as pam_total_all
from batches as b
left join cat as c on c.combined_ref = b.combined_ref
left join pam as m on m.combined_ref = b.combined_ref
order by b.capex_month, b.combined_ref;
