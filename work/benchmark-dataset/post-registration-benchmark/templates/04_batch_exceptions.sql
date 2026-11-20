-- ============================================================================
-- 04_batch_exceptions — step 5 of METHOD.md. One row per batch, one column per
-- known problem, so a reader sees at a glance which issue touches which book
-- and by how much. Built for escalation to the servicer.
--
--   RUN     mise run sql -- work/benchmark-dataset/post-registration-benchmark/templates/04_batch_exceptions.sql
--   GRAIN   one row per PAM COMBINED_REF. EVERY batch appears, including those
--           with nothing in CAT — a batch with no loan-level money is a
--           FINDING, not a row to drop.
--   COST    minutes — one CASES pass, one TRANSACTIONS pass
--   WORKED  FINDINGS.md §11 and ../../work/data-issues/intrum/escalations-portugal-millennium.md
--
-- THE COLUMNS, AND WHICH DIRECTION EACH PUSHES A COMPARISON
--   NO_CAT_MONEY      PAM reports cash this batch has no loan-level money for
--   LOOKS_LIKE_OPENING_POSTING  the batch's entire lifetime is ONE collecting
--                     month equal to its own ACQUISITIONPRINCIPAL to the cent.
--                     That is acquisition principal booked into the
--                     collections column, not cash. ⚠ Do not count it.
--   WIPED_REF_LOANS   newest CAT version has NO batch ref. Their payments are
--                     billed here on the last version that named a batch — a
--                     workaround, so WIPED_REF_EUR is the money resting on it
--   MOVED_OUT_LOANS   newest version names a batch OUTSIDE this scope: sold on
--   REATTRIBUTED_LOANS newest version names a DIFFERENT in-scope batch. PAM
--                     bills the money to one batch, CAT bills the loans to
--                     another — per-batch performance for both is wrong
--   UNDATED_EUR       real money with no date in any version -> CAT reads UNDER
--   PRE_CAPEX_EUR     CAT cash predating the purchase; PAM structurally cannot
--                     hold it -> CAT would read OVER. Not a fault either side
--   LAG_EUR           PAM months the CAT extract cannot see -> CAT reads UNDER.
--                     ⚠ PAM-ONLY, and it measures RUN-OFF not a fault: size it
--                     against LAG_VS_TRAILING_12M, not against lifetime
--   AMOUNTLESS_LOANS  loans with a row passing the payment filter with a NULL
--                     amount. Money unaffected; a payment COUNT is not
--
-- ⚠ THE DEDUPE HERE ADMITS AMOUNT-LESS ROWS ON PURPOSE, unlike 02_payments.sql.
--   Ranking puts NULL amounts last, so any transaction with a real version
--   still resolves to it and the money is identical; a transaction whose every
--   version is amount-less survives with a NULL amount, which is the only way
--   to count them in the same single pass. Money sums filter them back out.
--   ⚠ Do not copy this CTE into a money query.
--
-- ⚠ BUILD THIS INDEPENDENTLY OF 03_reconcile_cat_pam.sql WHERE YOU CAN. On the
--   Portugal build the two were written separately and reproduced each other's
--   per-batch breakdown to the cent. That agreement is the reason to trust
--   either one.
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
        p.colltotal               as collections,
        p.acquisitionprincipal    as acquisition_principal
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
    select
        combined_ref,
        max(capex_month)            as capex_month,
        max(acquisition_principal)  as acquisition_principal,
        count_if(collections <> 0)  as collecting_months,
        sum(collections)            as pam_lifetime
    from pam_rows
    group by combined_ref
),

-- Each loan's batch as this scope sees it: batch filter BEFORE the qualify, so
-- a loan whose newest version left the scope keeps its last in-scope batch.
cases_scope as (
    select
        c.long_portfolio_id as combined_ref,
        c.case_id
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'
      and c.long_portfolio_id in (select combined_ref from batches)
      and c.case_id not like '%-%'
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

-- The same loans' ACTUAL newest version, with no batch filter at all. The
-- difference between this and cases_scope is what the two REF columns report.
cases_latest as (
    select
        c.case_id,
        c.long_portfolio_id as newest_ref
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'
      and c.case_id in (select case_id from cases_scope)
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

loans as (
    select
        s.combined_ref,
        s.case_id,
        case when l.newest_ref is null                          then 'wiped'
             when l.newest_ref = s.combined_ref                 then 'unchanged'
             when l.newest_ref in (select combined_ref from batches)
                                                                then 'moved_in_scope'
             else                                                    'moved_out' end as ref_class
    from cases_scope as s
    left join cases_latest as l on l.case_id = s.case_id
),

-- ⚠ amount-less rows ADMITTED here, ranked last. See the header.
payments as (
    select
        t.case_id,
        max(t.transaction_date::date) over (
            partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        )                         as payment_date,
        -t.amount::decimal(38, 2) as amount
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
    where t._file_path like $raw_prefix || $source_system || '.transactions.%'
      and t.case_id in (select case_id from loans)
      and t.payment_cost_ind = 'P'
      and coalesce(t.booking_ind, 'N') != 'Y'
    qualify row_number() over (
        partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        order by iff(t.amount is null, 1, 0),
                 coalesce(t.record_updated, t.update_ts)::timestamp desc nulls last
    ) = 1
),

window_end as (
    select dateadd(day, -1, date_trunc('month', max(payment_date)))::date as last_complete_day
    from payments
    where amount is not null
),

cat as (
    select
        l.combined_ref,
        count(distinct l.case_id)                                         as cat_loans,
        count(distinct iff(l.ref_class = 'wiped',         l.case_id, null)) as wiped_ref_loans,
        count(distinct iff(l.ref_class = 'moved_out',     l.case_id, null)) as moved_out_loans,
        count(distinct iff(l.ref_class = 'moved_in_scope', l.case_id, null)) as reattributed_loans,
        -- p.case_id is not null: a loan with NO payment row at all is not
        -- "amount-less", it simply never paid.
        count(distinct iff(p.case_id is not null and p.amount is null,
                           l.case_id, null))                               as amountless_loans,
        sum(iff(p.amount is null, 0, p.amount))                           as cat_total_all,
        sum(iff(p.amount is not null and p.payment_date is null, p.amount, 0))
                                                                          as undated_eur,
        sum(iff(p.amount is not null and p.payment_date < b.capex_month, p.amount, 0))
                                                                          as pre_capex_eur,
        sum(iff(p.amount is not null and l.ref_class = 'wiped', p.amount, 0))
                                                                          as wiped_ref_eur,
        sum(iff(p.amount is not null
                and p.payment_date >= b.capex_month
                and p.payment_date <= w.last_complete_day, p.amount, 0))  as cat_matched
    from loans as l
    inner join batches as b on b.combined_ref = l.combined_ref
    left  join payments as p on p.case_id     = l.case_id
    cross join window_end as w
    group by l.combined_ref
),

pam as (
    select
        pr.combined_ref,
        sum(iff(pr.reporting_month <= date_trunc('month', w.last_complete_day),
                pr.collections, 0))                                       as pam_matched,
        sum(iff(pr.reporting_month >  date_trunc('month', w.last_complete_day),
                pr.collections, 0))                                       as lag_eur,
        sum(iff(pr.reporting_month >  dateadd(month, -12, date_trunc('month', w.last_complete_day))
                and pr.reporting_month <= date_trunc('month', w.last_complete_day),
                pr.collections, 0))                                       as pam_trailing_12m
    from pam_rows as pr
    cross join window_end as w
    group by pr.combined_ref
)

select
    b.combined_ref                                     as batch_id,
    b.capex_month,
    b.pam_lifetime,
    coalesce(c.cat_loans, 0)                           as cat_loans,
    coalesce(c.cat_total_all, 0)                       as cat_total_all,

    -- ---- flags -------------------------------------------------------------
    coalesce(c.cat_total_all, 0) = 0                   as no_cat_money,
    (b.collecting_months = 1
     and b.pam_lifetime = b.acquisition_principal)     as looks_like_opening_posting,

    -- ---- the period-matched residual ---------------------------------------
    coalesce(c.cat_matched, 0) + coalesce(c.undated_eur, 0)
        - coalesce(m.pam_matched, 0)                   as residual_after_undated,
    div0(coalesce(c.cat_matched, 0), nullif(coalesce(m.pam_matched, 0), 0)) as match_ratio,

    -- ---- one column per problem --------------------------------------------
    coalesce(c.undated_eur, 0)                         as undated_eur,
    coalesce(c.pre_capex_eur, 0)                       as pre_capex_eur,
    coalesce(m.lag_eur, 0)                             as lag_eur,
    div0(coalesce(m.lag_eur, 0), nullif(coalesce(m.pam_trailing_12m, 0), 0))
                                                       as lag_vs_trailing_12m,
    coalesce(c.wiped_ref_loans, 0)                     as wiped_ref_loans,
    coalesce(c.wiped_ref_eur, 0)                       as wiped_ref_eur,
    coalesce(c.moved_out_loans, 0)                     as moved_out_loans,
    coalesce(c.reattributed_loans, 0)                  as reattributed_loans,
    coalesce(c.amountless_loans, 0)                    as amountless_loans
from batches as b
left join cat as c on c.combined_ref = b.combined_ref
left join pam as m on m.combined_ref = b.combined_ref
order by b.capex_month, b.combined_ref;
