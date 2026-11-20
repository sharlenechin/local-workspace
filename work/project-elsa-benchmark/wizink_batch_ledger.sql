-- ============================================================================
-- wizink_batch_ledger — every WiZink batch Intrum bought in Portugal, in or
--                       out of the benchmark, with the reason in words
--
--   RUN     mise run sql -- work/project-elsa-benchmark/wizink_batch_ledger.sql
--           datalake.q("work/project-elsa-benchmark/wizink_batch_ledger", convert=False)
--   GRAIN   one row per PAM batch for the four one-off purchases; the 129
--           forward-flow batches collapse to ONE row, because listing them
--           individually runs to 133 rows and none of them is in the book.
--   COST    ~2 min (one CASES scan pinned to instance 4050).
--   SOURCE  PAM latest delivery for the acquisition side; raw CAT for ours.
--
-- Measured 2026-09-16. Pairs with accounts.sql / payments.sql — same scope
-- rules, so a batch marked "included" here is exactly the batch in the export.
--
-- ⚠ THE CAT_PCT_OF_PAM COLUMN HERE IS ON THE PRE-REGISTRATION-INCLUSIVE BASIS,
-- because that is what the +/-10% selection was originally decided on and the
-- commentary quotes both. payments.sql now defaults to EXCLUDING cash dated
-- before the case was registered ($drop_pre_registration = true), on which the
-- same twelve batches pass and the same three fail:
--     PT18019A000000  104.53% -> 97.82%   PT19007D010000   67.20% -> 66.65%
--     PT19013A020000  153.15% -> 152.38%  PT19013B010000   39.15% -> 38.97%
-- So the decision is basis-independent. Say which basis a quoted ratio is on.
-- ============================================================================
-- WHY ONLY ONE BATCH SURVIVES, IN ORDER
--   133 WiZink batches in PAM
--   -129  forward flow          PAM DEAL_TYPE_DESC = 'Ongoing'. Monthly
--                               deliveries, not a portfolio purchase. Five of
--                               them have NO cases in CAT at all while
--                               reporting EUR 379,244.37 of collections — a
--                               feed gap, and one for Intrum.
--     -3  fail reconciliation   CAT collections must land within +/-10% of
--                               PAM's over the SAME WINDOW. Both sides cut at
--                               2026-01, the CAT extract; PAM runs to 2026-07
--                               and a whole-against-whole ratio is not
--                               like-for-like. See payments.sql READ FIRST 2.
--   =  1  PT18019A000000
--
-- ⚠ TWO DEBT-AGE COLUMNS, AND ONLY ONE OF THEM IS SAFE
--   AVG_DEBT_AGE_YEARS      ours: mean(REGISTRATION_DATE - DEFAULT_DATE).
--                           This reproduces Intrum's OWN per-case AGE_OF_DEBT
--                           field (which is stored in DAYS) to five decimals,
--                           so it is their definition, computed consistently.
--                           USE THIS ONE.
--   PAM_AVG_DEBT_AGE_RAW    PAM's AVERAGE_DEBT_AGE exactly as delivered, with
--                           NO unit applied, because the column DOES NOT CARRY
--                           A CONSISTENT UNIT. On the Millennium batches it is
--                           YEARS; on these WiZink batches it is MONTHS.
--                           PT18019A000000 reads 31 — that is 31 months
--                           (2.58 years), against 2.82 years measured, not
--                           31 years. Returned only so the discrepancy stays
--                           visible. DO NOT PUT IT IN A COLUMN HEADED "YEARS".
--
-- ⚠ AVG_BALANCE IS ON PAM'S OWN TWO COLUMNS — acquired principal divided by
--   acquired cases. It is NOT our loan-level average: PAM counts cases at
--   acquisition and we count loans still in the feed today. Both are returned
--   so the two are never silently differenced.
--
-- ⚠ Nothing may follow the final semicolon.
-- ============================================================================

set country   = 'PT';
set seller    = '%WIZINK%';
set cat_cut   = '2026-01-31';   -- the CAT extract month; see payments.sql N1
set raw_pre   = 'data-prod-data-raw-sftp-071269be/intrum/cat.4050.';

with latest_delivery as (
    select *
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path = (
              select max(_file_path)
              from RAW.HYPERION_INTRUM_PAM.PAM
              where _file_path like '%/pam.pam.pam.2%'
          )
      and pmode_name = 'Real'
      and coalesce(is_ownership_change, 0) = 0
      and countrycode like $country
      and upper(seller_name) like $seller
),

-- The acquisition side, one row per batch. Single-valued columns taken with
-- max(), the two that post monthly with sum() — see portfolio_summary.sql N2.
pam as (
    select
        combined_ref                                as portfolio_id,
        max(deal_type_desc)                         as deal_type,
        year(max(capex_date_m)::date)               as capex_year,
        sum(rp_purchase_price)                      as capex_amount,
        max(acquisitionprincipal)                   as total_balance,
        max(acqcases)                               as total_accounts,
        max(average_debt_age)                       as pam_avg_debt_age_raw,
        sum(colltotal)                              as total_collections,
        sum(iff(period_start_date::date <= $cat_cut::date, colltotal, 0))
                                                    as pam_collections_to_cut
    from latest_delivery
    group by combined_ref
),

-- Our side. Same guards as accounts.sql: all extracts read, instance pinned,
-- container cases dropped, latest version per case.
-- ⚠ SCOPED TO THE ONE-OFF BATCHES ONLY, AND THAT IS NOT A DETAIL. accounts.sql
-- ranks a loan's versions among IN-SCOPE batches (its G2), and its scope is
-- One-off. Widening this CTE to all 133 batches lets a loan whose newest
-- version names a forward-flow batch pull out of its one-off batch, which
-- moved PT19013A020000 from 909 loans / 153.1% to 544 / 89.8% in a first
-- draft of this file — i.e. it would have reversed the +/-10% decision on
-- evidence the benchmark does not use. The one-off rows here MUST be computed
-- on the benchmark's own scope or they describe a different dataset.
-- Consequence: the forward-flow row carries PAM figures only. That is honest,
-- not a gap — those batches are not in the book and have no "our" side.
cases as (
    select
        c.long_portfolio_id           as portfolio_id,
        c.case_id                     as loan_id,
        c.original_capital            as registration_capital,
        c.registration_date::date     as registration_date,
        c.age_of_debt                 as intrum_age_of_debt_days
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_pre || 'cases.%'
      and c.long_portfolio_id in (
              select portfolio_id from pam where deal_type = 'One-off'
          )
      and c.case_id not like '%-%'
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

ours as (
    select
        c.portfolio_id,
        count(*)                                                as our_loans,
        sum(c.registration_capital)                             as our_capital,
        -- Intrum's own definition. Their AGE_OF_DEBT is in DAYS; this is the
        -- same quantity rebuilt from the dates so it exists on every loan.
        avg(datediff(day, dc.derived_default_date, c.registration_date) / 365.25)
                                                                as avg_debt_age_years
    from cases as c
    left join PROD.NPL_COMMON.DIM_CASE as dc
        on  dc.case_bk = '4050-' || c.loan_id
        and dc.is_current_flag
    group by c.portfolio_id
),

-- Sign-corrected (N2 in payments.sql), deduped on the team's own key.
txn as (
    select
        c.portfolio_id,
        -t.amount::decimal(38, 2) as amount
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
    inner join cases as c on c.loan_id = t.case_id
    where t._file_path like $raw_pre || 'transactions.%'
      and t.payment_cost_ind = 'P'
      and coalesce(t.booking_ind, 'N') != 'Y'
      and t.amount is not null
    qualify row_number() over (
        partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        order by coalesce(t.record_updated, t.update_ts)::timestamp desc nulls last
    ) = 1
),

cat as (
    select portfolio_id, sum(amount) as our_collections
    from txn group by portfolio_id
),

-- One-off batches stay individual; forward flow collapses to a single row.
combined as (
    select
        iff(p.deal_type = 'One-off', p.portfolio_id,
            '129 batches (forward flow)')           as portfolio_id,
        p.deal_type,
        iff(p.deal_type = 'One-off', min(p.capex_year)::varchar,
            min(p.capex_year) || '-' || max(p.capex_year))
                                                    as capex_year,
        sum(p.capex_amount)                         as capex_amount,
        sum(p.total_balance)                        as total_balance,
        sum(p.total_accounts)                       as total_accounts,
        -- Meaningless once 129 batches are added together, so nulled there.
        iff(p.deal_type = 'One-off', max(p.pam_avg_debt_age_raw), null)
                                                    as pam_avg_debt_age_raw,
        sum(p.total_collections)                    as total_collections,
        sum(p.pam_collections_to_cut)               as pam_collections_to_cut,
        sum(o.our_loans)                            as our_loans,
        sum(o.our_capital)                          as our_capital,
        -- Loan-weighted, so the rolled-up row is still a real average.
        sum(o.avg_debt_age_years * o.our_loans) / nullif(sum(o.our_loans), 0)
                                                    as avg_debt_age_years,
        sum(c.our_collections)                      as our_collections
    from pam as p
    left join ours as o on o.portfolio_id = p.portfolio_id
    left join cat  as c on c.portfolio_id = p.portfolio_id
    group by 1, 2
)

select
    portfolio_id,
    capex_year,
    capex_amount,
    -- Cents on the euro.
    iff(total_balance = 0, null, capex_amount / total_balance * 100) as price_pct,
    total_balance,
    total_accounts,
    -- PAM's own two columns divided. NOT our loan-level average.
    iff(total_accounts = 0, null, total_balance / total_accounts)    as avg_balance,
    avg_debt_age_years,                       -- ours. USE THIS
    pam_avg_debt_age_raw,                     -- unit differs by book. DO NOT LABEL
    total_collections,
    our_loans,
    our_capital,
    our_collections,
    -- The test the +/-10% rule is applied on, both sides cut at the CAT extract.
    iff(pam_collections_to_cut = 0, null,
        our_collections / pam_collections_to_cut * 100)              as cat_pct_of_pam,
    case
        when portfolio_id = 'PT18019A000000'
            then 'INCLUDED — 29,971 loans exported (5 company-debtor loans removed so the '
              || 'book is pure consumer), EUR 122,891,559.16 registration capital. Cleaning '
              || 'then drops 78 accounts — 77 whose default date falls after registration '
              || 'and 1 one-account 2019 vintage — leaving 29,893. Collections reconcile at '
              || '97.82% of PAM over the same window, on the basis that excludes cash '
              || 'collected before the case was registered ($drop_pre_registration in '
              || 'payments.sql). On the old basis it read 104.50%.'
        when portfolio_id = 'PT19007D010000'
            then 'EXCLUDED, whole batch — collections are 67.2% of PAM, outside +/-10%. '
              || 'Only 3,604 loans found against PAM''s 4,633 accounts, and Intrum''s own '
              || 'AGE_OF_DEBT is delivered on 7.2% of them. Thinly delivered.'
        when portfolio_id = 'PT19013A020000'
            then 'EXCLUDED, whole batch — collections are 153.1% of PAM, outside +/-10%. '
              || 'Over-delivery this large is not pre-capex cash; it is unexplained and '
              || 'one for Intrum.'
        when portfolio_id = 'PT19013B010000'
            then 'EXCLUDED, whole batch — collections are 39.2% of PAM, outside +/-10%. '
              || '232 loans against PAM''s 310 accounts.'
        else 'EXCLUDED, all 129 — forward flow (PAM DEAL_TYPE_DESC = ''Ongoing''), monthly '
          || 'deliveries rather than a portfolio purchase. Includes 5 batches with no cases '
          || 'in CAT at all despite reporting EUR 379,244.37 of collections, and two 2017 '
          || 'batches that have never collected anything on EUR 278,844.63 of capex. Both '
          || 'are for Intrum.'
    end                                                             as commentary
from combined
order by deal_type, capex_year, portfolio_id;
