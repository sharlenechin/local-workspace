-- ============================================================================
-- base_reconciliation — do two numbers that should agree, agree? And if not, why?
-- GRAIN: one row per reconciliation check.
-- ============================================================================
-- base_data_quality asks "is this column populated and plausible".
-- This asks "do the levels agree, and what is the MECHANISM when they don't".
-- Every row carries a DIAGNOSIS, so a gap is attributed rather than flagged.
--
--   Extension : open and Run All
--   Terminal  : mise run sql -- work/servicing/prod/base_reconciliation.sql
--   Notebook  : datalake.q("servicing/prod/base_reconciliation")
--
-- ---------------------------------------------------------------------------
-- DIAGNOSIS values:
--   RECONCILES      agree within $tolerance. Shown deliberately — a check
--                   that silently stopped running looks identical to a
--                   passing one, and only one of those is good news.
--   FEED_COVERAGE   the two sides cover different populations. The Intrum
--                   PAM feed reports portfolio aggregates with no loan
--                   detail, so loan-level sums legitimately fall short.
--   SOURCE_DEFINITION  both sides are populated but measure different things,
--                   and the difference varies by servicer. Not fixable in SQL
--                   — pick one level and stay on it.
--   VERSIONED_KEY   a join used the SCD2 CASE_SK / BORROWER_SK where the
--                   durable CASE_BK / BORROWER_ID was needed.
--   CURRENCY        the difference is a mixed-currency sum.
--   DATA_QUALITY    a value is impossible or a population is implausible.
--
-- All figures in the comments were measured at $month_end = 2026-07-31 on
-- 2026-09-09 and will drift. Re-run rather than trusting them.
-- ============================================================================

set month_end        = '2026-07-31';
set portfolio_filter = '%';
set tolerance        = 0.01;    -- 1% relative


with scope as (
    select portfolio_sk, portfolio_bk
    from PROD.NPL_COMMON.DIM_PORTFOLIO
    where portfolio_bk like $portfolio_filter
),

-- ---------------------------------------------------------------------------
-- Aggregates, each at portfolio x currency for the reporting month.
-- ---------------------------------------------------------------------------
pf as (
    select f.portfolio_sk, f.currency_id,
           max(f.deal_source_sk)        as deal_source_sk,
           sum(f.gross_cash_recoveries) as gcr,
           sum(f.total_balance)         as total_balance
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY as f
    inner join scope s on s.portfolio_sk = f.portfolio_sk
    where f.period_end_date = $month_end::date
    group by 1, 2
),

loan_collect as (
    select c.portfolio_sk, c.currency_id, sum(c.amount) as amount
    from PROD.NPL_COMMON.FCT_CASE_COLLECTION as c
    inner join scope s on s.portfolio_sk = c.portfolio_sk
    where c.collection_date >  dateadd(month, -1, $month_end::date)
      and c.collection_date <= $month_end::date
    group by 1, 2
),

loan_balance as (
    select b.portfolio_sk, b.currency_id,
           count(*)                  as n_loans,
           sum(b.outstanding_total)  as outstanding_total
    from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY as b
    inner join scope s on s.portfolio_sk = b.portfolio_sk
    where b.date_day = $month_end::date
    group by 1, 2
),

-- ---- 1. collections, loan level vs portfolio level, per currency ----------
collections_by_ccy as (
    select pf.currency_id,
           count(*)                                as portfolios,
           sum(iff(lc.amount is null, 1, 0))       as portfolios_no_loan_detail,
           sum(pf.gcr)                             as portfolio_gcr,
           sum(coalesce(lc.amount, 0))             as loan_gcr
    from pf
    left join loan_collect lc
           on lc.portfolio_sk = pf.portfolio_sk and lc.currency_id = pf.currency_id
    group by 1
),

-- ---- 2. balance, by deal source: this is where the mechanism shows -------
balance_by_source as (
    select coalesce(ds.deal_source_name, '(no deal source)') as deal_source_name,
           count(distinct pf.portfolio_sk)                   as portfolios,
           sum(pf.total_balance)                             as portfolio_balance,
           sum(coalesce(lb.outstanding_total, 0))            as loan_balance
    from pf
    left join loan_balance lb
           on lb.portfolio_sk = pf.portfolio_sk and lb.currency_id = pf.currency_id
    left join PROD.NPL_COMMON.DIM_DEAL_SOURCE ds on ds.deal_source_sk = pf.deal_source_sk
    group by 1
),

-- ---- 3. carrying: portfolio level vs the loan-level allocation of it -----
carrying_cmp as (
    select count(*)                                           as portfolios_with_carrying,
           sum(iff(la.alloc is null, 1, 0))                    as portfolios_no_allocation,
           sum(pc.closing)                                     as total_closing,
           sum(coalesce(la.alloc, 0))                          as total_allocated,
           sum(iff(la.alloc is null, pc.closing, 0))           as closing_not_allocated
    from (select portfolio_sk, sum(closing_value::number(38, 6)) as closing
          from PROD.NPL_COMMON.FCT_CARRYING_AMOUNT
          where period_end_date = $month_end::date
            and period_end_date <= current_date()
          group by 1) pc
    left join (select p.portfolio_sk,
                      sum(m.allocated_carrying_amount::number(38, 6)) as alloc
               from PROD.NPL_COMMON.MART_NPL_CARRYING_AMOUNT_CASE_ALLOCATION m
               inner join PROD.NPL_COMMON.DIM_PORTFOLIO p on p.portfolio_bk = m.portfolio_bk
               where m.date_day = $month_end::date
               group by 1) la on la.portfolio_sk = pc.portfolio_sk
),

-- ---- 4/5. the flash mart vs the facts it is built from -------------------
flash_cmp as (
    select sum(f.gcf_actual) as flash_actual,
           sum(f.gcf_active) as flash_active
    from PROD.NPL_COMMON.MART_NPL_FLASH_REPORT f
    inner join scope s on s.portfolio_bk = f.portfolio_bk
    where f.month_end_date = $month_end::date
),
fact_cmp as (
    select (select sum(gcr) from pf) as fact_actual,
           (select sum(f.gross_collection_forecast)
            from PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY f
            inner join scope s on s.portfolio_sk = f.portfolio_sk
            where f.period_end_date = $month_end::date) as fact_active
),

-- ---- 6. the borrower bridge, by version vs by durable loan key -----------
book_versions as (
    select b.case_sk, dc.case_bk
    from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY b
    inner join scope s on s.portfolio_sk = b.portfolio_sk
    inner join PROD.NPL_COMMON.DIM_CASE dc on dc.case_sk = b.case_sk
    where b.date_day = $month_end::date
),
borrower_cmp as (
    select
        (select count(distinct bo.borrower_id)
         from PROD.NPL_COMMON.BRG_CASE_BORROWER br
         inner join book_versions bv on bv.case_sk = br.case_sk
         inner join PROD.NPL_COMMON.DIM_BORROWER bo on bo.borrower_sk = br.borrower_sk)
                                                                as via_case_sk,
        (select count(distinct bo.borrower_id)
         from PROD.NPL_COMMON.DIM_CASE dc
         inner join PROD.NPL_COMMON.BRG_CASE_BORROWER br on br.case_sk = dc.case_sk
         inner join PROD.NPL_COMMON.DIM_BORROWER bo on bo.borrower_sk = br.borrower_sk
         where dc.case_bk in (select case_bk from book_versions))
                                                                as via_case_bk
),

-- ---- 7. how often multi-currency actually bites, across ALL months -------
currency_cmp as (
    select count(*)                    as portfolio_months,
           sum(iff(n_cur > 1, 1, 0))   as multi_currency_months,
           max(n_cur)                  as max_currencies
    from (select portfolio_sk, period_end_date, count(distinct currency_id) as n_cur
          from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
          group by 1, 2)
),

-- ---- 8. orphan dimension keys: facts pointing at dimension rows that
--         do not exist. An INNER join on any of these silently drops money.
orphan_keys as (
    select 'deal_source_sk' as fk, 'DIM_DEAL_SOURCE' as dim, count(*) as rows_affected,
           count(distinct f.deal_source_sk) as keys, sum(f.total_balance) as amount
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f
    inner join scope s on s.portfolio_sk = f.portfolio_sk
    where f.period_end_date = $month_end::date and f.deal_source_sk is not null
      and f.deal_source_sk not in (select deal_source_sk from PROD.NPL_COMMON.DIM_DEAL_SOURCE)
    union all
    select 'deal_sk', 'DIM_DEAL', count(*), count(distinct f.deal_sk), sum(f.total_balance)
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f
    inner join scope s on s.portfolio_sk = f.portfolio_sk
    where f.period_end_date = $month_end::date and f.deal_sk is not null
      and f.deal_sk not in (select deal_sk from PROD.NPL_COMMON.DIM_DEAL)
    union all
    select 'segment_sk', 'DIM_SEGMENT', count(*), count(distinct f.segment_sk), sum(f.total_balance)
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f
    inner join scope s on s.portfolio_sk = f.portfolio_sk
    where f.period_end_date = $month_end::date and f.segment_sk is not null
      and f.segment_sk not in (select segment_sk from PROD.NPL_COMMON.DIM_SEGMENT)
    union all
    select 'security_class_sk', 'DIM_SECURITY_CLASS', count(*),
           count(distinct f.security_class_sk), sum(f.total_balance)
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f
    inner join scope s on s.portfolio_sk = f.portfolio_sk
    where f.period_end_date = $month_end::date and f.security_class_sk is not null
      and f.security_class_sk not in (select security_class_sk from PROD.NPL_COMMON.DIM_SECURITY_CLASS)
    union all
    select 'legal_buyer_sk', 'DIM_LEGAL_BUYER', count(*),
           count(distinct f.legal_buyer_sk), sum(f.total_balance)
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f
    inner join scope s on s.portfolio_sk = f.portfolio_sk
    where f.period_end_date = $month_end::date and f.legal_buyer_sk is not null
      and f.legal_buyer_sk not in (select legal_buyer_sk from PROD.NPL_COMMON.DIM_LEGAL_BUYER)
    union all
    select 'product_sk', 'DIM_PRODUCT', count(*), count(distinct f.product_sk), sum(f.total_balance)
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f
    inner join scope s on s.portfolio_sk = f.portfolio_sk
    where f.period_end_date = $month_end::date and f.product_sk is not null
      and f.product_sk not in (select product_sk from PROD.NPL_COMMON.DIM_PRODUCT)
    union all
    select 'batch_sk', 'DIM_BATCH', count(*), count(distinct f.batch_sk), sum(f.total_balance)
    from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f
    inner join scope s on s.portfolio_sk = f.portfolio_sk
    where f.period_end_date = $month_end::date and f.batch_sk is not null
      and f.batch_sk not in (select batch_sk from PROD.NPL_COMMON.DIM_BATCH)
),

checks as (
    select 1 as id, 'COLLECTIONS' as topic,
        iff(abs(div0(loan_gcr, portfolio_gcr) - 1) <= $tolerance, 'RECONCILES',
            iff(portfolios_no_loan_detail > 0, 'FEED_COVERAGE', 'SOURCE_DEFINITION')) as diagnosis,
        'Collections, loan level vs portfolio level — ' || currency_id as check_name,
        to_varchar(portfolios) || ' portfolio(s), ' || to_varchar(portfolios_no_loan_detail)
          || ' with no loan detail; loan level sees '
          || to_varchar(round(100 * div0(loan_gcr, portfolio_gcr), 2)) || '%'  as measured,
        'A shortfall is the PAM (portfolio-aggregate) vs CAT (loan-level) feed '
          || 'split. Loan-level collections are NOT a total; use '
          || 'monthly_portfolio_performance.'                                  as what_to_do
    from collections_by_ccy

    union all
    select 2, 'BALANCE',
        iff(abs(div0(loan_balance, portfolio_balance) - 1) <= $tolerance,
            'RECONCILES',
            iff(loan_balance = 0 or portfolio_balance = 0, 'DATA_QUALITY', 'SOURCE_DEFINITION')),
        'Book size, loan level vs portfolio level — ' || deal_source_name,
        to_varchar(portfolios) || ' portfolio(s); loan level is '
          || to_varchar(round(100 * div0(loan_balance, portfolio_balance), 2))
          || '% of portfolio level',
        'THE TWO LEVELS DO NOT MEASURE THE SAME THING, and the difference is '
          || 'per-servicer: measured 2026-07-31 at 146.9% for ORANGE/HEIMDALL, '
          || '112.2% BLUE/LOKI, 102.9% LEGACY, 100.2% GESCOBRO, 87.0% ORGANIC. '
          || 'It is not principal-vs-total either (principal alone ranges '
          || '51.6%-110.8% of portfolio balance). Quote book size from ONE '
          || 'level, name which, and never cross-check one against the other.'
    from balance_by_source

    union all
    select 3, 'CARRYING',
        iff(abs(div0(total_allocated, total_closing) - 1) <= $tolerance,
            'RECONCILES', 'FEED_COVERAGE'),
        'Loan-level carrying allocation vs portfolio carrying',
        to_varchar(portfolios_with_carrying) || ' portfolio(s) with carrying, '
          || to_varchar(portfolios_no_allocation) || ' with no loan-level allocation ('
          || to_varchar(round(closing_not_allocated, 2)) || '); allocated '
          || to_varchar(round(100 * div0(total_allocated, total_closing), 2)) || '%',
        'The unallocated portion is entirely portfolios with no loan detail — '
          || 'at 2026-07-31, 66 of 251 portfolios and EUR 93.3m, which is the '
          || 'whole 3.15% gap. The allocation mart also covers only 9 '
          || 'month-ends (2025-12 .. 2026-08); outside them it is empty, not zero.'
    from carrying_cmp

    union all
    select 4, 'FLASH',
        iff(abs(div0(f.flash_actual, c.fact_actual) - 1) <= $tolerance, 'RECONCILES', 'CURRENCY'),
        'Flash report GCF_ACTUAL vs the portfolio fact',
        'flash ' || to_varchar(round(f.flash_actual, 2)) || ' vs fact '
          || to_varchar(round(c.fact_actual, 2)),
        'Totals match. A PER-CURRENCY split will not: the flash model collapses '
          || 'currency with any_value(), so its label is arbitrary for a '
          || 'multi-currency portfolio while the sums mix currencies.'
    from flash_cmp f cross join fact_cmp c

    union all
    select 5, 'FORECAST',
        iff(abs(div0(f.flash_active, c.fact_active) - 1) <= $tolerance, 'RECONCILES', 'GRAIN'),
        'Flash GCF_ACTIVE vs the accounting forecast fact',
        'flash ' || to_varchar(round(f.flash_active, 2)) || ' vs fact '
          || to_varchar(round(c.fact_active, 2)),
        'If these diverge the mart and the fact were built from different '
          || 'vintages — say which one a number came from.'
    from flash_cmp f cross join fact_cmp c

    union all
    select 6, 'BORROWER',
        iff(via_case_bk = via_case_sk, 'RECONCILES', 'VERSIONED_KEY'),
        'Borrowers reachable via CASE_SK vs via CASE_BK',
        'via CASE_SK ' || to_varchar(via_case_sk) || '; via CASE_BK '
          || to_varchar(via_case_bk) || ' — difference '
          || to_varchar(via_case_bk - via_case_sk) || ' ('
          || to_varchar(round(100.0 * (via_case_bk - via_case_sk)
                              / nullif(via_case_bk, 0), 4)) || '%)',
        'BRG_CASE_BORROWER is keyed on (CASE_SK, BORROWER_SK) — both versioned, '
          || 'per its own dbt model comment. Joining it to the snapshot on '
          || 'CASE_SK reaches only the version on book. The effect on a '
          || 'borrower COUNT is small (~1.7k of 16.4m, 0.01%), but do not '
          || 'assume it is small for a borrower-level SUM.'
    from borrower_cmp

    union all
    select 7, 'CURRENCY',
        iff(multi_currency_months = 0, 'RECONCILES', 'CURRENCY'),
        'Portfolio-months spanning more than one currency',
        to_varchar(multi_currency_months) || ' of ' || to_varchar(portfolio_months)
          || ' portfolio-months ('
          || to_varchar(round(100.0 * multi_currency_months / nullif(portfolio_months, 0), 2))
          || '%) span 2+ currencies, max ' || to_varchar(max_currencies),
        'Rare but real, so the guard is still needed — and note it is 0 at '
          || 'some month-ends, so checking one month proves nothing. Convert '
          || 'with ref_fx_rate (rate_type PMI, MULTIPLY, do not invert).'
    from currency_cmp

    union all
    select 8, 'ORPHAN_KEY',
        iff(rows_affected = 0, 'RECONCILES', 'DATA_QUALITY'),
        'FCT_PORTFOLIO_SNAPSHOT_MONTHLY.' || fk || ' not in ' || dim,
        to_varchar(rows_affected) || ' row(s), ' || to_varchar(keys)
          || ' distinct key(s), balance at risk ' || to_varchar(round(amount, 2)),
        'AN INNER JOIN ON THIS DIMENSION SILENTLY DROPS THAT BALANCE. Measured '
          || '2026-07-31: the ''-1'' Unknown sentinel is used for deal_source, '
          || 'deal, segment, security_class and legal_buyer (203 rows, EUR '
          || '1.15bn) and for product_sk (70 rows, EUR 10.70bn) — but the '
          || 'dimensions are keyed by hash, so -1 matches nothing. batch_sk has '
          || '3 genuinely orphaned hashes (EUR 74.4m). Always LEFT join these '
          || 'and treat a NULL name as ''Unknown'', never as a row to discard. '
          || 'FCT_CASE_SNAPSHOT_DAILY is clean — this is portfolio-level only.'
    from orphan_keys

    union all
    -- 9. The one that matters most: a PORTFOLIO_SK the portfolio dimension
    --    has never heard of. Every file here scopes by DIM_PORTFOLIO, so an
    --    inner join drops it entirely.
    select 9, 'ORPHAN_PORTFOLIO',
        iff(rows_affected = 0, 'RECONCILES', 'DATA_QUALITY'),
        src || '.PORTFOLIO_SK not in DIM_PORTFOLIO',
        to_varchar(rows_affected) || ' row(s), amount ' || to_varchar(round(amount, 2)),
        'DIM_PORTFOLIO is keyed by hash so the ''-1'' Unknown sentinel matches '
          || 'nothing. Measured 2026-09-09: FCT_PORTFOLIO_SNAPSHOT_MONTHLY 1,853 '
          || 'rows / EUR 16.92bn balance / EUR 38.11m collections — at 2026-07-31 '
          || 'that is 2.69% OF THE MONTH''S COLLECTIONS; '
          || 'FCT_PORTFOLIO_SNAPSHOT_MONTHLY_VERSIONED 13,707 rows / EUR 153.61bn; '
          || 'FORECAST_SERVICER 36,852 rows / EUR 450.59m. The accounting and '
          || 'underwriting forecasts, FCT_CARRYING_AMOUNT and MART_NPL_FLASH_REPORT '
          || 'are clean, so actual-vs-forecast variance was distorted in one '
          || 'direction only. monthly_portfolio_performance, '
          || 'monthly_portfolio_restatement and monthly_portfolio_forecast now '
          || 'UNION the orphan in and label it ''(unknown portfolio -1)''.'
    from (
        select 'FCT_PORTFOLIO_SNAPSHOT_MONTHLY' as src, count(*) as rows_affected,
               sum(total_balance) as amount
        from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
        where period_end_date = $month_end::date
          and portfolio_sk not in (select portfolio_sk from PROD.NPL_COMMON.DIM_PORTFOLIO)
        union all
        select 'FCT_PORTFOLIO_SNAPSHOT_MONTHLY_VERSIONED', count(*), sum(total_balance)
        from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY_VERSIONED
        where period_end_date = $month_end::date
          and portfolio_sk not in (select portfolio_sk from PROD.NPL_COMMON.DIM_PORTFOLIO)
        union all
        select 'FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY', count(*),
               sum(gross_collection_forecast)
        from PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY
        where period_end_date = $month_end::date
          and portfolio_sk not in (select portfolio_sk from PROD.NPL_COMMON.DIM_PORTFOLIO)
    )

    union all
    -- 10. Dimension uniqueness. A duplicate SK fans out every join that uses
    --     it, inflating money with no error. All 16 passed on 2026-09-09.
    select 10, 'DIM_UNIQUENESS',
        iff(sum(dupes) = 0 and sum(nulls) = 0, 'RECONCILES', 'DATA_QUALITY'),
        'Dimension keys unique and non-null',
        to_varchar(count(*)) || ' dimension(s) checked, '
          || to_varchar(sum(dupes)) || ' duplicate key(s), '
          || to_varchar(sum(nulls)) || ' null key(s)',
        'A duplicate dimension row multiplies every fact row that joins to it. '
          || 'Checked: portfolio, batch, deal, deal_source, segment, product, '
          || 'security_class, legal_buyer, reporting_system, case, borrower.'
    from (
        select count(*) - count(distinct portfolio_sk) as dupes,
               sum(iff(portfolio_sk is null, 1, 0)) as nulls
        from PROD.NPL_COMMON.DIM_PORTFOLIO
        union all select count(*) - count(distinct batch_sk), sum(iff(batch_sk is null,1,0))
        from PROD.NPL_COMMON.DIM_BATCH
        union all select count(*) - count(distinct deal_sk), sum(iff(deal_sk is null,1,0))
        from PROD.NPL_COMMON.DIM_DEAL
        union all select count(*) - count(distinct deal_source_sk), sum(iff(deal_source_sk is null,1,0))
        from PROD.NPL_COMMON.DIM_DEAL_SOURCE
        union all select count(*) - count(distinct segment_sk), sum(iff(segment_sk is null,1,0))
        from PROD.NPL_COMMON.DIM_SEGMENT
        union all select count(*) - count(distinct product_sk), sum(iff(product_sk is null,1,0))
        from PROD.NPL_COMMON.DIM_PRODUCT
        union all select count(*) - count(distinct security_class_sk), sum(iff(security_class_sk is null,1,0))
        from PROD.NPL_COMMON.DIM_SECURITY_CLASS
        union all select count(*) - count(distinct legal_buyer_sk), sum(iff(legal_buyer_sk is null,1,0))
        from PROD.NPL_COMMON.DIM_LEGAL_BUYER
        union all select count(*) - count(distinct reporting_system_sk), sum(iff(reporting_system_sk is null,1,0))
        from PROD.NPL_COMMON.DIM_REPORTING_SYSTEM
        union all select count(*) - count(distinct case_sk), sum(iff(case_sk is null,1,0))
        from PROD.NPL_COMMON.DIM_CASE
        union all select count(*) - count(distinct borrower_sk), sum(iff(borrower_sk is null,1,0))
        from PROD.NPL_COMMON.DIM_BORROWER
    )

    union all
    -- 11. Is the collapsed portfolio fact reproducible as max(snapshot_version)
    --     of the versioned one? Nearly, but not exactly.
    select 11, 'COLLAPSED_VS_VERSIONED',
        iff(mismatches = 0, 'RECONCILES', 'SOURCE_DEFINITION'),
        'Collapsed portfolio fact vs latest version of _VERSIONED',
        to_varchar(mismatches) || ' of ' || to_varchar(pairs)
          || ' portfolio-currency pair(s) differ',
        'DO NOT try to reproduce one table from the other. Measured 2026-07-31: '
          || '5 of 6 differences are the (unknown -1) portfolio, which the '
          || 'versioned table does not carry for SEK/CHF/GBP/DKK and shows as '
          || 'GCR 0 for EUR. Exactly ONE real portfolio differs '
          || '(LEG-ES25002-U01/2512 EUR, EUR 3,040.72). So '
          || 'monthly_portfolio_restatement''s IS_LATEST_VERSION does not always '
          || 'mark the row monthly_portfolio_performance reports.'
    from (
        select count(*) as pairs,
               sum(iff(abs(coalesce(c.gcr,0) - coalesce(v.gcr,0)) > 0.01
                       or c.portfolio_sk is null or v.portfolio_sk is null, 1, 0)) as mismatches
        from (select portfolio_sk, currency_id, sum(gross_cash_recoveries) gcr
              from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY
              where period_end_date = $month_end::date group by 1,2) c
        full outer join
             (select portfolio_sk, currency_id, sum(gross_cash_recoveries) gcr
              from (select * from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY_VERSIONED
                    where period_end_date = $month_end::date
                    qualify snapshot_version = max(snapshot_version)
                            over (partition by portfolio_sk, period_end_date))
              group by 1,2) v
          on v.portfolio_sk = c.portfolio_sk and v.currency_id = c.currency_id
    )

    union all
    -- 12. The carrying allocation mart against the loan snapshot it allocates.
    select 12, 'ALLOCATION',
        iff(mismatched = 0 and not_in_snapshot = 0, 'RECONCILES', 'DATA_QUALITY'),
        'Allocation mart OUTSTANDING_TOTAL vs the loan snapshot',
        to_varchar(loans) || ' loan(s); ' || to_varchar(mismatched)
          || ' mismatched, ' || to_varchar(not_in_snapshot) || ' absent from snapshot',
        'A clean pass here means the loan-level carrying allocation sits on the '
          || 'same balances as ref_loan and monthly_loan_performance, so the two '
          || 'can be joined safely.'
    from (
        select count(*) as loans,
               sum(iff(abs(m.outstanding_total - s.outstanding_total) > 0.01, 1, 0)) as mismatched,
               sum(iff(s.case_sk is null, 1, 0)) as not_in_snapshot
        from PROD.NPL_COMMON.MART_NPL_CARRYING_AMOUNT_CASE_ALLOCATION m
        left join PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY s
               on s.case_sk = m.case_sk and s.date_day = m.date_day
        where m.date_day = $month_end::date
    )

    union all
    -- 13. Forbearance: the flag on the snapshot vs the forbearance table.
    select 13, 'FORBEARANCE',
        iff(flagged_no_row = 0 and unflagged_with_row = 0, 'RECONCILES', 'DATA_QUALITY'),
        'FORBEARANCE_FLAG vs FCT_CASE_FORBEARANCE',
        to_varchar(flagged_no_row) || ' loan(s) flagged True with no forbearance '
          || 'row; ' || to_varchar(unflagged_with_row) || ' flagged False with one',
        'The two sources disagree, so pick one per number and say which. '
          || 'FCT_CASE_FORBEARANCE is one row per CASE (not per event) and has '
          || 'only a start date — no end date, so duration, cure and re-default '
          || 'are not measurable from it.'
    from (
        select sum(iff(s.forbearance_flag and f.case_sk is null, 1, 0)) as flagged_no_row,
               sum(iff(not s.forbearance_flag and f.case_sk is not null, 1, 0)) as unflagged_with_row
        from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY s
        left join PROD.NPL_COMMON.FCT_CASE_FORBEARANCE f on f.case_sk = s.case_sk
        where s.date_day = $month_end::date
    )

    union all
    -- 14. The canonical dashboard number. Any BI tool showing $month_end must
    --     match this exactly; if it does not, the dashboard is wrong.
    select 14, 'DASHBOARD_TOTAL',
        'RECONCILES',
        'Canonical EUR collections and portfolio count for the month',
        to_varchar(portfolios) || ' portfolios, EUR '
          || to_varchar(round(collections_eur, 2)) || ' collected'
          || iff(unconverted_rows > 0,
                 ' (WARNING: ' || to_varchar(unconverted_rows)
                 || ' row(s) had no FX rate and are EXCLUDED)', ''),
        'Verified 2026-09-09: agg_collections_monthly (batch grain), '
          || 'agg_portfolio_summary (portfolio grain) and the raw fact all '
          || 'return EUR 41,282,117.95 for 2026-07-31 — identical to the cent. '
          || 'Compare any dashboard against this figure. FX is PMI, MULTIPLIED. '
          || 'Note $month_end must be a COMPLETE month: the newest month is '
          || 'routinely part-loaded (2026-08-31 had 7 portfolios vs July''s 250).'
    from (
        select count(distinct f.portfolio_sk)             as portfolios,
               sum(f.gross_cash_recoveries * fx.rate)     as collections_eur,
               sum(iff(fx.rate is null, 1, 0))            as unconverted_rows
        from PROD.NPL_COMMON.FCT_PORTFOLIO_SNAPSHOT_MONTHLY f
        left join (
            select date_day as m, quote_currency as c, monthly_avg as rate
            from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
            where base_currency = 'EUR' and rate_type = 'PMI' and quote_currency <> 'EUR'
            union all
            select date_day, 'EUR', 1
            from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
            where base_currency = 'EUR' and quote_currency = 'EUR'
        ) fx on fx.c = f.currency_id and fx.m = f.period_end_date
        where f.period_end_date = $month_end::date
    )

    union all
    -- 15. The country dimension resolves. DIM_COUNTRY.COUNTRY_ID is a hash
    --     key while every fact carries ISO alpha-2 codes, so a join on
    --     country_id matches nothing and country_name is NULL everywhere
    --     with no error (found 2026-09-09; had hit all five files that join
    --     the dimension). Every file now joins on ISO_ALPHA2_CODE; this
    --     proves it still resolves and sizes the non-ISO 'UK' residue.
    select 15, 'COUNTRY',
        iff(unresolved_non_uk = 0, 'RECONCILES', 'DATA_QUALITY'),
        'Loan snapshot country codes vs DIM_COUNTRY.ISO_ALPHA2_CODE',
        to_varchar(n_codes) || ' code(s) on book: ' || to_varchar(via_iso)
          || ' resolve via ISO_ALPHA2_CODE, ' || to_varchar(via_country_id)
          || ' via COUNTRY_ID; ' || to_varchar(uk_loans) || ' loan(s) carry non-ISO ''UK'''
          || iff(unresolved_non_uk > 0, '; UNRESOLVED: ' || unresolved_codes, ''),
        'Join DIM_COUNTRY on ISO_ALPHA2_CODE, never on COUNTRY_ID. ''UK'' is '
          || 'not ISO (GB is) and resolves to nothing; keep it visible as the raw '
          || 'code rather than folding it into Unknown — merging it with GB is a '
          || 'data-team decision. Any other unresolved code is new: report it.'
    from (
        select count(distinct s.country_id)                                          as n_codes,
               count(distinct iff(iso.iso_alpha2_code is not null, s.country_id, null)) as via_iso,
               count(distinct iff(cid.country_id is not null, s.country_id, null))      as via_country_id,
               sum(iff(s.country_id = 'UK', 1, 0))                                     as uk_loans,
               count(distinct iff(iso.iso_alpha2_code is null and s.country_id <> 'UK',
                                  s.country_id, null))                                as unresolved_non_uk,
               listagg(distinct iff(iso.iso_alpha2_code is null and s.country_id <> 'UK',
                                    s.country_id, null), ',')                         as unresolved_codes
        from PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY s
        left join PROD.COMMON.DIM_COUNTRY iso on iso.iso_alpha2_code = s.country_id
        left join PROD.COMMON.DIM_COUNTRY cid on cid.country_id      = s.country_id
        where s.date_day = $month_end::date
    )
)

select id, topic, diagnosis, check_name, measured, what_to_do
from checks
order by iff(diagnosis = 'RECONCILES', 2, 1), id, check_name
