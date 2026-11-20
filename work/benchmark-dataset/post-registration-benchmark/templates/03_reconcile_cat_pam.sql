-- ============================================================================
-- 03_reconcile_cat_pam — step 4 of METHOD.md, and the step that makes the
-- dataset defensible. Like-for-like CAT payments against PAM collections, with
-- every source of difference broken out as its own column.
--
--   RUN     mise run sql -- work/benchmark-dataset/post-registration-benchmark/templates/03_reconcile_cat_pam.sql
--   GRAIN   one row per batch (PAM COMBINED_REF)
--   COST    minutes — one pass over the transaction feed
--   WORKED  FINDINGS.md §10 (Portugal: 99.88% whole-vs-whole was a coincidence)
--
-- ⚠ A WHOLE-AGAINST-WHOLE RATIO IS WORTHLESS. Two large opposite errors cancel
--   in it. Read MATCH_RATIO and RESIDUAL_AFTER_UNDATED together, never alone.
--
-- THE FOUR DIFFERENCES, AND WHICH WAY EACH PUSHES
--   1 PAM's lifetime starts at the capex month; CAT carries the servicer's
--     earlier history                                 -> CAT OVER, col CAT_PRE_CAPEX
--   2 CAT's extract lags PAM's newest actuals month   -> CAT UNDER, col PAM_AFTER_WINDOW
--   3 CAT payments with no date in any version        -> CAT UNDER, col CAT_UNDATED
--   4 PAM restates past months as late cash lands     -> either way; newest file only
--
-- HOW TO READ IT
--   · The window CLOSES AT THE LAST COMPLETE CAT MONTH, derived not hardcoded,
--     on both sides — a partial final month would depress the match for nothing.
--   · MATCH_RATIO is period-matched but does NOT credit undated cash.
--     RESIDUAL_AFTER_UNDATED does, and is the figure to quote.
--   · POSTREG_RATIO repeats the match from each CASE's own registration date
--     instead of the batch capex month. Different question: "what came in while
--     the servicer held the case" vs "what could PAM possibly report". Both are
--     defensible; say which you used.
--   · A batch short by roughly its undated share is explained. Anything left is
--     unexplained and belongs in 04_batch_exceptions.sql and the escalation.
--   · ⚠⚠ BUT ASK HOW MUCH WORK THE UNDATED CASH IS DOING. UNDATED_SHARE_OF_GAP
--     answers it. Above 0.5 the residual passes mostly on cash nobody can place
--     in time, and RECONCILIATION_STATUS says RECONCILES WITH RESERVATION. That
--     is not a failure -- it is a batch whose closure rests on an assumption,
--     and it must be reported as such rather than counted as clean.
--
-- GUARDS: those of 00_scope/01_accounts/02_payments — one PAM file,
-- PMODE_NAME='Real', no ownership-change rows, CASES and TRANSACTIONS deduped
-- to latest version, instance pinned, payments only, AMOUNT negated, date
-- recovered across versions.
-- ⚠ Nothing may follow the final semicolon.
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
    inner join newest_pam_file as nf on nf.file_path = p._file_path
    where p.pmode_name = 'Real'
      and coalesce(p.is_ownership_change, 0) = 0
      and p.countrycode like $country
      and upper(p.seller_name) like upper($seller)
      and p.period_start_date::date < date_trunc('month', to_timestamp_ntz(
              parse_json(p._file_metadata):extract_ts::string,
              'YYYYMMDDTHH24MISS'))::date
),

batches as (
    select combined_ref, max(capex_month) as capex_month
    from pam_rows
    group by combined_ref
),

cases as (
    select
        c.long_portfolio_id       as combined_ref,
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

-- The window closes at the last COMPLETE month in the CAT feed. Derived here,
-- never hardcoded — the extract moves.
window_end as (
    select dateadd(day, -1, date_trunc('month', max(payment_date)))::date as last_complete_day
    from payments
),

cat as (
    select
        c.combined_ref,
        sum(p.amount)                                                           as cat_total_all,
        sum(iff(p.payment_date is null, p.amount, 0))                           as cat_undated,
        sum(iff(p.payment_date <  b.capex_month, p.amount, 0))                  as cat_pre_capex,
        sum(iff(p.payment_date >  w.last_complete_day, p.amount, 0))            as cat_after_window,
        sum(iff(p.payment_date >= b.capex_month
                and p.payment_date <= w.last_complete_day, p.amount, 0))        as cat_matched,
        sum(iff(p.payment_date <  c.registration_date, p.amount, 0))            as cat_pre_registration,
        sum(iff(p.payment_date >= c.registration_date
                and p.payment_date <= w.last_complete_day, p.amount, 0))        as cat_postreg_matched
    from payments as p
    inner join cases   as c on c.case_id      = p.case_id
    inner join batches as b on b.combined_ref = c.combined_ref
    cross join window_end as w
    group by c.combined_ref
),

pam as (
    select
        pr.combined_ref,
        sum(pr.collections)                                                     as pam_total_all,
        sum(iff(pr.reporting_month <= date_trunc('month', w.last_complete_day),
                pr.collections, 0))                                             as pam_matched,
        sum(iff(pr.reporting_month >  date_trunc('month', w.last_complete_day),
                pr.collections, 0))                                             as pam_after_window,
        -- twelve complete months to the window close, so the lag can be sized
        -- against a recent run rate rather than against a whole lifetime.
        sum(iff(pr.reporting_month >  dateadd(month, -12, date_trunc('month', w.last_complete_day))
                and pr.reporting_month <= date_trunc('month', w.last_complete_day),
                pr.collections, 0))                                             as pam_trailing_12m
    from pam_rows as pr
    cross join window_end as w
    group by pr.combined_ref
)

select
    b.combined_ref                                as batch_id,
    b.capex_month,

    -- ---- the like-for-like pair, cut at the capex month -------------------
    coalesce(c.cat_matched, 0)                    as cat_matched,
    coalesce(m.pam_matched, 0)                    as pam_matched,
    div0(coalesce(c.cat_matched, 0), nullif(coalesce(m.pam_matched, 0), 0)) as match_ratio,
    -- ⚠ THE FIGURE TO QUOTE: matched cash plus undated cash, against PAM.
    coalesce(c.cat_matched, 0) + coalesce(c.cat_undated, 0)
        - coalesce(m.pam_matched, 0)              as residual_after_undated,
    div0(coalesce(c.cat_matched, 0) + coalesce(c.cat_undated, 0),
         nullif(coalesce(m.pam_matched, 0), 0))   as residual_ratio,
    -- ⚠⚠ HOW MUCH OF THE CLOSURE IS UNDATED CASH DOING? Crediting undated cash
    -- is legitimate -- it is real money the servicer cannot place in time -- but
    -- it closes a gap without explaining it. Where undated exceeds HALF the raw
    -- shortfall, the residual passes on cash nobody can date, and the batch is
    -- RECONCILED WITH RESERVATION, not reconciled. Same arithmetic, honest label.
    div0(coalesce(c.cat_undated, 0),
         nullif(abs(coalesce(m.pam_matched, 0) - coalesce(c.cat_matched, 0)), 0))
                                                  as undated_share_of_gap,
    case
        when coalesce(m.pam_matched, 0) = 0                       then 'NO PAM CASH'
        when abs(coalesce(c.cat_matched, 0) + coalesce(c.cat_undated, 0)
                 - coalesce(m.pam_matched, 0))
             > greatest(1000, 0.01 * abs(coalesce(m.pam_matched, 0)))
                                                                  then 'DOES NOT RECONCILE'
        when coalesce(c.cat_undated, 0)
             > 0.5 * abs(coalesce(m.pam_matched, 0) - coalesce(c.cat_matched, 0))
                                                   then 'RECONCILES WITH RESERVATION'
        else                                            'RECONCILES'
    end                                           as reconciliation_status,

    -- ---- the same pair, cut at each case's own registration date -----------
    coalesce(c.cat_postreg_matched, 0)            as cat_postreg_matched,
    div0(coalesce(c.cat_postreg_matched, 0), nullif(coalesce(m.pam_matched, 0), 0)) as postreg_ratio,
    coalesce(c.cat_pre_registration, 0)           as cat_pre_registration,

    -- ---- what was excluded, and why ---------------------------------------
    coalesce(c.cat_pre_capex, 0)                  as cat_pre_capex,     -- diff 1: CAT over
    coalesce(m.pam_after_window, 0)               as pam_after_window,  -- diff 2: CAT under
    div0(coalesce(m.pam_after_window, 0),
         nullif(coalesce(m.pam_trailing_12m, 0), 0)) as lag_vs_trailing_12m,
    coalesce(c.cat_undated, 0)                    as cat_undated,       -- diff 3: CAT under
    coalesce(c.cat_after_window, 0)               as cat_after_window,  -- partial final month

    -- ---- unmatched totals, for reference ----------------------------------
    coalesce(c.cat_total_all, 0)                  as cat_total_all,
    coalesce(m.pam_total_all, 0)                  as pam_total_all
from batches as b
left join cat as c on c.combined_ref = b.combined_ref
left join pam as m on m.combined_ref = b.combined_ref
order by b.capex_month, b.combined_ref;
