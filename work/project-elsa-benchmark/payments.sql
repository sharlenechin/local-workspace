-- ============================================================================
-- payments — collections per loan per payment date, Project Elsa:
--            Portugal / Millennium + WiZink
--
--   RUN      mise run sql -- work/project-elsa-benchmark/payments.sql
--            datalake.q("work/project-elsa-benchmark/payments", convert=False)
--   GRAIN    one row per (LOAN_ID, PAYMENT_DATE). A loan that paid on 40 days
--            has 40 rows — aggregate up before joining.
--   PAIRS    accounts.sql on (PORTFOLIO_ID, LOAN_ID) — identical population.
--   RUNTIME  ~4.5 min. Every extract of a 24.7bn-row table, no date bound.
--   SOURCE   raw Intrum CAT feed, instance 4050. EUR, not FX-converted.
--
-- Millennium figures measured 2026-09-10; WiZink added and everything
-- re-measured 2026-09-16. Pre-registration cash removed the same day (G9,
-- READ FIRST 4) and every figure below re-measured after it.
-- ============================================================================
-- RETURNS  798,774 rows × 6 columns, over 67,503 loans that ever paid,
--          12 batches. Collections 201,224,598.53.
--
--          Millennium  473,656 rows  51,848 loans  158,078,425.40
--          WiZink      325,118 rows  15,655 loans   43,146,173.13
--
--   SELLER_NAME              'Millennium' or 'Wizink'. Returned so a total can
--                            be split without joining back to accounts. The
--                            two books are 13 and 8 years apart in vintage and
--                            recover at 17.442% and 35.109% of capital — a
--                            blended rate describes no book that exists.
--   PORTFOLIO_ID             batch ref; joins to accounts.sql
--   LOAN_ID                  raw CASE_ID; joins to accounts.sql
--   PAYMENT_DATE               TRANSACTION_DATE. NULL if no version had one.
--                              Millennium spans 2005-07-01 to 2026-01-14,
--                              WiZink 2018-12-19 to 2026-01-13. Both now open
--                              at a registration date, never before one (G9).
--   MISSING_PAYMENT_DATE_FLAG  true on 5,407,533.41 (2.68731%) of collections.
--                              Essentially all Millennium: WiZink's undated
--                              total is a single reversal of EUR -1.62.
--   TOTAL_COLLECTIONS          EUR, sign-corrected. See N2 and N5.
--
-- There is deliberately NO payment count — see N3.
--
-- ============================================================================
-- READ FIRST — three things that make a total wrong
-- ============================================================================
-- 1. THIS IS NOT "COLLECTIONS TO DATE". It is collections to the CAT extract
--    date (last payment 2026-01-14) PLUS undated cash. PAM's newest delivery
--    reports actuals through 2026-07, so PAM holds six months this file
--    cannot: EUR 1,653,076.48 across these batches. Read anything recent from
--    PAM, not from here.
--
-- 2. NEVER QUOTE A CAT-vs-PAM RATIO WITHOUT THE PERIOD CUT. Whole against
--    whole Millennium reads 99.88% of PAM and THAT FIGURE IS A COINCIDENCE —
--    two opposite errors cancel in it (CAT missing Feb-Jul 2026 against CAT's
--    undated cash that PAM already counted before the cut).
--    Cut both sides at the last COMPLETE CAT month (2025-12) and, with
--    pre-registration cash gone (G9), the real relationship appears —
--    measured 2026-09-16 from this file, undated cash credited:
--        CAT matched + undated     201,053,396.18
--        PAM matched               202,345,776.28
--        CAT is 99.36130% of PAM    -1,292,380.10
--    Per batch the range is 98.16997%-101.29145%. ALL TWELVE sit within
--    +/-2%, well inside the +/-10% selection rule:
--        highest  PT15018G000000  101.29145  the only batch above 100
--        lowest   PT18019A000000   98.16997  WiZink; read 104.50% before G9
--                 PT16023C000000   99.75190  read 101.51% before G9
--    Full working in ../benchmark/archive/pam_cat_match.sql, which reports the
--    capex cut and the post-registration cut side by side, per batch.
--    ⚠ THE RATIO ONLY HOLDS WITH UNDATED CASH CREDITED. Strip it and
--    PT08018B000000 reads 89.50935%, which would fail the +/-10% rule on its
--    own; its true residual is -0.10716%. See READ FIRST 3.
--    ⚠ THE +/-10% RULE THAT SELECTED THESE BATCHES LIVES IN accounts.sql E2.
--    The three excluded WiZink one-offs are quoted there on the pre-G9 basis.
--
-- 3. UNDATED CASH IS REAL MONEY AND IT IS KEPT. Filter on PAYMENT_DATE for any
--    time series and the total falls short by 5,407,533.41. Do NOT filter it
--    out and then quote the remainder as the book's collections.
--    ⚠ IT IS A MILLENNIUM PROBLEM ONLY. WiZink's undated total is a single
--    reversal of EUR -1.62, so the 2.68731% portfolio figure is 3.42079% of
--    Millennium and nothing at all of WiZink. Do not apply one rate to both.
--    Lifetime recovery against registration capital, re-measured after G9 —
--    every rate fell, because pre-registration cash left the numerator:
--        Millennium  17.44104% on all cash, 16.84441% on dated cash only
--        WiZink      35.10914%
--        combined    19.55059%  <- describes neither book; always say which
--
-- 4. PRE-REGISTRATION CASH IS EXCLUDED (G9, added 2026-09-16 on request).
--    Payments dated before Intrum opened the case are the seller's own
--    pre-sale history. PAM structurally cannot report them — a batch's PAM
--    life starts at acquisition — so keeping them made two batches read over
--    100% of PAM on a like-for-like window.
--    Removed: EUR 4,919,333.95 over 25,563 rows, on 9 of the 12 batches.
--        Millennium  1,966,738.65  largest PT15018G000000 1,573,045.73 (4.41%
--                                  of that batch), then PT16023C000000
--                                  322,493.00 and PT050030000000 61,383.43
--        WiZink      2,952,595.30  6.40% of PT18019A000000
--    733 loans leave the file entirely: every payment they had predated their
--    own registration date.
--    ⚠ UNDATED CASH IS NOT TOUCHED. It carries no date to test, so all
--    5,407,533.41 of it survives. A "no pre-registration cash" claim can only
--    ever cover dated cash.
--    ⚠ accounts.sql IS UNCHANGED and did not need to change — it holds no
--    payment dates, so its loan population and REGISTRATION_CAPITAL are
--    unaffected. The two files still pair on (PORTFOLIO_ID, LOAN_ID), with
--    payments still a subset of accounts.
--    Set $drop_pre_registration to false to return the old basis.
--
-- ============================================================================
-- COLUMN NOTES
-- ============================================================================
-- N1 THE DATE IS RECOVERED ACROSS VERSIONS, then kept NULL if still absent.
--    Before recovery, 190,189 of 542,385 deduped payments carry no
--    transaction date — 58,556,660.58, 36.5% of the money. The date is taken
--    as the latest non-null value across ALL versions of a transaction, not
--    from the winning version alone, which recovers roughly 53m that a naive
--    `where transaction_date is not null` throws away. What no version dates
--    stays in the file with MISSING_PAYMENT_DATE_FLAG true — 5,407,535.03. An
--    earlier version bounded the date instead and silently lost 5,450,225.84.
--    ⚠ Never bound this date. There are ZERO pre-1990 and ZERO future-dated
--    payments in the deduped set; the 1979 and 2028 values in the raw column
--    belong to non-payment rows or superseded versions and never arrive here.
--    PAYMENT_DATE is TRANSACTION_DATE, not BANKING_DATE or REGISTRATION_DATE —
--    it is when the payment is attributed, which is what a curve wants.
-- N2 AMOUNT IS STORED SIGN-FLIPPED. Intrum sends a collection as a negative;
--    stg_intrum_cat__transactions reads -AMOUNT and so does this file. A plain
--    sum of the raw column gives the right magnitude with the wrong sign.
-- N3 NO PAYMENT COUNT, because it could only mislead. Rows pass Intrum's own
--    payment filter carrying a NULL amount and NULL currency, on every batch —
--    43,658 loans across the twelve (11,418 on PT050030000000, then 5,141 ·
--    4,906 · 4,226 · 4,038 · 3,390 · 3,318 · 3,155 · 1,553 · 1,384 · 1,129;
--    see ../benchmark/archive/batch_impact_matrix.sql). `amount is not null` excludes them so they
--    cannot invent zero-value payment dates. KEEP THAT GUARD — money is
--    unaffected either way, but without it these rows create (LOAN_ID,
--    PAYMENT_DATE) rows with a NULL total. Worth raising with Intrum.
-- N5 EVERYTHING IS EUR, SO CURRENCY IS NOT RETURNED (changed 2026-09-11 on
--    request). CURRENCY_ID used to be in the grain as a guard. Verified before
--    removing it: of the 474,900 Millennium rows then returned (pre-G9; now
--    473,656), 474,899 are EUR and exactly ONE has no
--    currency at all — loan 1959892 on PT08010C000000, an undated EUR 1,732.52
--    mirroring a payment of the same amount on 2017-08-31 that was reversed on
--    2017-12-05. No other currency appears anywhere, and the balance side
--    agrees: CASES.CURRENCY_CAP_INTEREST — the currency of ORIGINAL_CAPITAL and
--    ORIGINAL_INTEREST — is 'EUR' on all 120,713 loans, no nulls and no other
--    value. So NO FX CONVERSION IS NEEDED OR PERFORMED in either file: there is
--    nothing denominated in anything else to convert.
--    Collapsing currency out of
--    the grain merges ZERO rows (474,900 distinct (batch, loan, date) either
--    way), so row count and totals are unchanged.
--    ⚠ NOTHING IS FILTERED — that null-currency row is summed as EUR, which is
--    right here. It is also why there is no `currency = 'EUR'` predicate: such
--    a filter would silently drop its 1,732.52.
--    RE-VERIFIED FOR WIZINK 2026-09-16: CASES.CURRENCY_CAP_INTEREST is 'EUR'
--    on all 71,851 WiZink cases bar one, which carries no currency at all —
--    the same shape as Millennium's single exception, and again summed as EUR.
--    ⚠ THIS IS A GUARD THAT WAS REMOVED, NOT ONE THAT PASSED. If $country or
--    $sellers change, this file will sum across currencies without saying so.
--    Re-read this note before reusing it outside PT / Millennium + WiZink.
-- N4 THE DEDUPE KEY IS THE TEAM'S, INCLUDING ITS WEAKNESS. concat() returns
--    NULL if any argument is NULL, so payments with a NULL ORIG_TR_ID collapse
--    into one partition and all but one is discarded.
--    int_npl_case_collection_intrum has the same shape, so this file agrees
--    with PROD. At 99.36130% of PAM on the period-matched basis (READ FIRST 2)
--    it is evidently not losing much here — that is evidence, not proof.
--
-- ============================================================================
-- GUARDS
-- ============================================================================
-- G1 TRANSACTIONS IS A CHANGE-HISTORY FEED — 133,930,261 rows for ~12.35m real
--    payments in this scope (10.8×). Deduped on (CASE_ID, ORIG_TR_ID ||
--    coalesce(PKEY,'')), latest RECORD_UPDATE wins. PKEY is in the key because
--    Denmark splits one transaction across rows. See N4.
-- G2 PAYMENTS ONLY: payment_cost_ind = 'P' and booking_ind <> 'Y', Intrum's
--    own rule. Without it the sum includes costs and fees.
-- G3 CASE_ID IS UNIQUE ONLY WITHIN A SOURCE SYSTEM, so it is pinned on
--    _file_path. This matters more here than anywhere: unpinned, this scope's
--    loans match rows in 601 transaction files against 11 in their own
--    instance. Verified to lose nothing — only 4050 holds cases for these
--    batch refs, so the pin excludes foreign rows and never this scope's own.
-- G4 ALL EXTRACTS ARE READ. Pinning the newest loses 4.6% overall and 10.4% on
--    one batch; for 4050, split_part(max(_file_path),'.',4) lands on a
--    2,486-row delta.
-- G5 CASES deduped to latest version per loan before use as the scope, with
--    the batch filter BEFORE the dedupe. Reordering drops 2,313 loans carrying
--    6,856,071.22 of in-window collections PAM still reports. Same guard, same
--    reason, as accounts.sql G2 — see there for the measurement.
--
-- ⚠ POPULATION IS accounts.sql's, AND IT NOW HAS TWO RULES, NOT ONE.
--   1. loans with no borrower type in the raw feed are dropped because they
--      cannot be priced — 169 of them (168 Millennium, 1 WiZink; it was 335
--      while PROD still decided the type);
--   2. WiZink's 5 company-debtor loans are dropped so that book is carried as
--      pure consumer (accounts.sql E3). Millennium KEEPS its 12,844 SME loans.
-- Both live in priceable_loans below. Change either in one file and you must
-- change it in the other — the notebook asserts both, because they drifted
-- once before.
-- ⚠ $exclude_batches REMOVES NO ROWS HERE FOR THE THREE MILLENNIUM BATCHES —
-- none of them has a payment in CAT, so it is symmetry with accounts.sql, not
-- a filter. IT DOES REMOVE ROWS FOR THE THREE WIZINK ONES, which have real
-- collections in CAT and are excluded because those collections do not
-- reconcile to PAM within +/-10% over the same window. Dropping the variable
-- would silently add EUR 8.2m of unreconciled cash to the book.
-- ⚠ THE PRICEABLE FILTER COST 183,230.30 ON THE PRE-G9 BASIS, where this file
-- returned 160,045,164.05 for Millennium against a 160,228,394.35 whole-
-- population figure, the gap being entirely those 168 loans. Millennium now
-- returns 158,078,425.40. ⚠ THE 183,230.30 HAS NOT BEEN RE-MEASURED SINCE G9 —
-- some of those loans' cash may itself have been pre-registration. So a
-- CAT-vs-PAM ratio computed from this file carries one MORE known difference
-- than the analysis describes. To
-- undo, clear $exclude_batches and delete the priceable_loans filter — in
-- BOTH files, never one.
--
-- JOINING TO accounts.sql: aggregate to loan level FIRST, then LEFT join. The
-- full rule and the failure modes are in accounts.sql; do not restate them.
--
-- ============================================================================
-- ON THE TWO `in (select ...)` FILTERS — why one was changed and one was not
-- ============================================================================
-- `long_portfolio_id in (select combined_ref from batches)` stays a semi-join:
-- `batches` is 14 rows referenced once, so a join saves no read, and a
-- semi-join cannot fan out where an inner join can. Nothing to win.
-- The transaction scan DID change: it used to filter `case_id in (select
-- loan_id from cases)` and then reference `cases` again in the final select
-- for PORTFOLIO_ID. Snowflake does not guarantee a CTE is materialised, so
-- that was potentially two passes over every CASES extract. One inner join
-- inside the payments CTE does both jobs in one read.
-- ⚠ The saving came from reading `cases` once, NOT from the join operator.
-- Snowflake compiles `in (subquery)` to a semi-join and pushes it down exactly
-- as it does an inner join, so swapping the operator alone buys nothing and
-- only adds fan-out risk. The prefix match is deliberately literal with no
-- leading wildcard, because Snowflake cannot prune a pattern that starts
-- with one.
--
-- ⚠ NOTHING MAY FOLLOW THE FINAL SEMICOLON, not even a comment.
-- ============================================================================

set country         = 'PT';
set sellers         = 'MILLENNIUM|WIZINK';
set deal_type       = 'One-off';
set source_system   = '4050';
set raw_prefix      = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
-- G9: drop cash dated before the case's own REGISTRATION_DATE. Set to false to
-- return it. See READ FIRST 4.
set drop_pre_registration = true;
set exclude_batches = 'PT06014B010000,PT070040000000,PT15018A040000,'
                   || 'PT19007D010000,PT19013A020000,PT19013B010000';


-- Scope: PAM collapsed to one row per batch before anything joins to it.
with batches as (
    select distinct
        combined_ref,
        iff(upper(seller_name) like '%WIZINK%', 'Wizink', 'Millennium') as seller_name
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path = (
              select max(_file_path)
              from RAW.HYPERION_INTRUM_PAM.PAM
              where _file_path like '%/pam.pam.pam.2%'
          )
      and pmode_name = 'Real'
      and coalesce(is_ownership_change, 0) = 0
      and countrycode like $country
      and regexp_like(upper(seller_name), '.*(' || $sellers || ').*')
      and deal_type_desc = $deal_type
),

-- One row per loan, latest version, batch filter before the qualify (G5).
-- SELLER_NAME is attached here so the priceable rule below can apply the
-- WiZink-only SME exclusion without a second pass over `batches`.
cases as (
    select
        b.seller_name,
        c.long_portfolio_id       as portfolio_id,
        c.case_id                 as loan_id,
        -- Same expression as accounts.sql's cases CTE, so the two files bound
        -- on an identical date. G9.
        c.registration_date::date as registration_date
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    inner join batches as b
        on b.combined_ref = c.long_portfolio_id
    where c._file_path like $raw_prefix || $source_system || '.cases.%'   -- G3, G4
      and c.case_id not like '%-%'
      and not ($source_system = '2080' and coalesce(c.real_case_ind, '') = '1')
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

-- accounts.sql's population: a loan is priceable if the raw feed puts any
-- P or C on it. Equivalent to accounts.sql's `has_company = 1 or has_private
-- = 1`, collapsed into the having clause so no second CTE is needed.
-- ⚠ NO row_number() here — RECORD_UPDATE ties at the latest version on 97.4%
-- of debtor slots, so picking one row would resolve arbitrarily and the
-- population would not reproduce between runs. See accounts.sql G6.
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
    inner join cases as c on c.loan_id = d.case_id   -- for SELLER_NAME only
    where d.ts = d.max_ts   -- EVERY row at the latest version, not one of them
    group by d.case_id, c.seller_name
    having max(iff(d.type in ('C', 'P'), 1, 0)) = 1
       -- E3, mirroring accounts.sql: WiZink carries no SME. Both files must
       -- apply this or the populations stop pairing.
       and not (c.seller_name = 'Wizink' and max(iff(d.type = 'C', 1, 0)) = 1)
),

-- One row per real payment (G1-G4), already carrying its batch. The join to
-- `cases` sits INSIDE this CTE on purpose: it cuts the scan to the scope
-- before the dedupe window runs AND attaches PORTFOLIO_ID in the same read.
payments as (
    select
        c.seller_name,
        c.portfolio_id,
        c.loan_id,
        c.registration_date,
        -- Latest non-null date across every version of this transaction (N1).
        max(t.transaction_date::date) over (
            partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        )                         as payment_date,
        -t.amount::decimal(38, 2) as amount            -- sign-flipped at source (N2)
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS as t
    inner join cases as c
        on c.loan_id = t.case_id
    where t._file_path like $raw_prefix || $source_system || '.transactions.%'
      and t.payment_cost_ind = 'P'                     -- G2
      and coalesce(t.booking_ind, 'N') != 'Y'          -- G2
      and t.amount is not null                         -- amount-less rows (N3)
    qualify row_number() over (
        partition by t.case_id, concat(t.orig_tr_id, coalesce(t.pkey, ''))
        order by coalesce(t.record_updated, t.update_ts)::timestamp desc nulls last
    ) = 1                                              -- G1
)

select
    seller_name,
    portfolio_id,
    loan_id,
    payment_date,
    payment_date is null as missing_payment_date_flag,
    -- EUR. Currency is deliberately no longer in the grain — N5 has the
    -- measurement that makes summing across it safe for THIS scope only.
    sum(amount)          as total_collections
from payments
where loan_id in (select loan_id from priceable_loans)
  and not array_contains(portfolio_id::variant, split($exclude_batches, ','))
  -- G9 PRE-REGISTRATION CASH IS EXCLUDED. Payments dated before Intrum opened
  -- the case are the seller's own pre-sale history, which PAM structurally
  -- cannot report because a batch's PAM life starts at acquisition. Keeping
  -- them made two batches read over 100% of PAM. Undated cash is KEPT: it has
  -- no date to test, and dropping it would lose real money (READ FIRST 3).
  and (
      not $drop_pre_registration
      or payment_date is null
      or payment_date >= registration_date
  )
group by seller_name, portfolio_id, loan_id, payment_date
order by seller_name, portfolio_id, loan_id, payment_date nulls last;
