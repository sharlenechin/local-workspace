-- ============================================================================
-- 02_payments — step 3 of METHOD.md. One row per loan per payment date.
--
--   RUN     mise run sql -- work/benchmark-dataset/post-registration-benchmark/templates/02_payments.sql
--           datalake.q("benchmark/templates/02_payments", convert=False)
--   GRAIN   one row per (LOAN_ID, PAYMENT_DATE). A loan that paid on 40 days
--           has 40 rows — aggregate up before joining to accounts.
--   PAIRS   01_accounts.sql on (PORTFOLIO_ID, LOAN_ID) — identical population.
--   COST    minutes. Every extract of the transaction feed, no date bound.
--   WORKED  ../../project-elsa-benchmark/payments.sql + FINDINGS.md §9
--
-- GUARDS (FINDINGS.md §5):
--   C2  TRANSACTIONS is a CHANGE-HISTORY feed (10.8x). Deduped on
--       (CASE_ID, ORIG_TR_ID || coalesce(PKEY,'')), latest RECORD_UPDATE wins.
--       PKEY is in the key because some countries split one transaction
--       across rows. ⚠ concat() returns NULL if any part is NULL, so rows
--       with a null ORIG_TR_ID collapse into one partition — this is the
--       team's own key and its own weakness, kept so figures agree with PROD.
--   C6  payments only: payment_cost_ind='P' and booking_ind<>'Y'
--   C7  AMOUNT is stored SIGN-FLIPPED — a collection arrives negative
--   C4/C5  instance pinned as a literal prefix; all extracts read
--   amount is not null — amount-less rows pass the servicer's payment filter
--       and would invent zero-value payment dates. Money is unaffected.
--
-- ⚠ THE DATE IS RECOVERED ACROSS VERSIONS, then kept NULL if still absent.
--   Any version may carry a date the winning version lacks (Portugal: that
--   rescued EUR 53m). NEVER bound this date instead — sentinel years live on
--   superseded versions and never survive the dedupe, so a bound only deletes
--   real money.
-- ⚠ UNDATED CASH IS REAL MONEY AND IT IS KEPT, flagged not dropped. Filter on
--   PAYMENT_DATE for a time series and the total falls short — do not then
--   quote the remainder as the book's collections.
-- ⚠ NO PAYMENT COUNT is returned. Check the amount-less rows before adding one.
-- ⚠ THIS IS NOT "COLLECTIONS TO DATE" — it stops at the CAT extract, which can
--   be months behind PAM. Read anything recent from PAM. See 06_feed_lag.sql.
-- ⚠ Nothing may follow the final semicolon.
-- ============================================================================

set country         = 'PT';
set seller          = 'MILLENNIUM';
set source_system   = '4050';         -- from 00_scope.sql block B
set raw_prefix      = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
set exclude_batches = '';             -- keep identical to 01_accounts.sql


with batches as (
    select distinct combined_ref
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path = (
              select max(_file_path)
              from RAW.HYPERION_INTRUM_PAM.PAM
              where _file_path like '%/pam.pam.pam.2%'
          )
      and pmode_name = 'Real'
      and coalesce(is_ownership_change, 0) = 0
      and countrycode like $country
      and upper(seller_name) like upper($seller)
),

-- One row per loan, latest version, batch filter before the qualify (C8).
cases as (
    select
        c.long_portfolio_id as portfolio_id,
        c.case_id           as loan_id
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'
      and c.long_portfolio_id in (select combined_ref from batches)
      and c.case_id not like '%-%'
      and not ($source_system = '2080' and coalesce(c.real_case_ind, '') = '1')
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

-- 01_accounts.sql's population, so the two files pair exactly: a loan is
-- priceable if the raw feed puts any P or C on it. ⚠ No row_number() — see C10.
priceable_loans as (
    select d.case_id as loan_id
    from (
        select
            b.case_id,
            b.type,
            coalesce(b.record_updated, b.update_ts)::timestamp as ts,
            max(coalesce(b.record_updated, b.update_ts)::timestamp) over (
                partition by b.case_id, b.debtor_row_number
            ) as max_ts
        from RAW.HYPERION_INTRUM_CAT.DEBTORS as b
        where b._file_path like $raw_prefix || $source_system || '.debtors.%'
          and b.case_id in (select loan_id from cases)
          and coalesce(b.deleted, 0)  = 0
          and coalesce(b.archived, 0) = 0
          and coalesce(b.unlinked, 0) = 0
    ) as d
    where d.ts = d.max_ts
    group by d.case_id
    having max(iff(d.type in ('C', 'P'), 1, 0)) = 1
),

-- One row per real payment, already carrying its batch. The join to `cases`
-- sits INSIDE this CTE on purpose: it cuts the scan to the scope before the
-- dedupe window runs AND attaches PORTFOLIO_ID in the same read.
payments as (
    select
        c.portfolio_id,
        c.loan_id,
        -- Latest non-null date across every version of this transaction.
        max(t.transaction_date::date) over (
            partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        )                         as payment_date,
        -t.amount::decimal(38, 2) as amount            -- sign-flipped at source (C7)
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
    inner join cases as c
        on c.loan_id = t.case_id
    where t._file_path like $raw_prefix || $source_system || '.transactions.%'
      and t.payment_cost_ind = 'P'                     -- C6
      and coalesce(t.booking_ind, 'N') != 'Y'          -- C6
      and t.amount is not null                         -- amount-less rows
    qualify row_number() over (
        partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        order by coalesce(t.record_updated, t.update_ts)::timestamp desc nulls last
    ) = 1                                              -- C2
)

select
    portfolio_id,
    loan_id,
    payment_date,                            -- TRANSACTION_DATE, not banking/booking
    payment_date is null as missing_payment_date_flag,
    sum(amount)          as total_collections
from payments
where loan_id in (select loan_id from priceable_loans)
  and ($exclude_batches = ''
       or not array_contains(portfolio_id::variant, split($exclude_batches, ',')))
group by portfolio_id, loan_id, payment_date
order by portfolio_id, loan_id, payment_date nulls last;
