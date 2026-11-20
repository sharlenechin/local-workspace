-- ============================================================================
-- loan_phase_history — one row per Italian loan, with its amicable -> legal
-- phase journey, durations and loan type. Intrum CAT instance 4034.
--
--   RUN      mise run sql -- work/italy/legal/loan_phase_history.sql
--            datalake.q("work/italy/legal/loan_phase_history", convert=False)
--   GRAIN    one row per LOAN_ID. 48,547 rows. Nothing is dropped.
--   RUNTIME  ~2 minutes.  Money is EUR.
--   SOURCE   RAW.HYPERION_INTRUM_CAT — CASES + GROUP_CASE_PHASE only.
--
-- ============================================================================
-- READ THIS FIRST — WHAT THIS BOOK CAN AND CANNOT ANSWER
-- ============================================================================
-- ⚠ THERE ARE ONLY TWO PHASES ON THIS INSTANCE, NOT A LADDER.
--   GROUP_CASE_PHASE holds exactly two codes for 4034, measured 2026-09-15:
--     A002  48,546 loans (every loan)      "amicable"
--     L002  17,003 loans (35.02%)          "legal"
--   There is no third code, and CUSTOM_CODE — the field that would carry a
--   sub-phase — is 100% NULL. So there is NO decreto ingiuntivo / precetto /
--   pignoramento breakdown in this feed. One transition exists: A002 -> L002.
--   Every loan starts in A002; zero loans appear in L002 without A002.
--
-- ⚠ THE LEGAL_* AND INSOLVENCY TABLES ARE EMPTY FOR 4034. Measured
--   2026-09-15, row counts for this instance:
--     LEGAL_INFO 0, LEGAL_STEPS 0, LEGAL_RESULT_INFO 0, LEGAL_STEP_PARTIES 0,
--     BANKRUPTCY_RECORD 0, ASSIGNMENT 0, SETTLEMENT 0, DEBT_CHARGES 0,
--     CASE_PRODUCT 0, PRODUCT_HISTORY 0, CASE_EXTENSION 0.
--   Those tables hold judgement dates, verdict amounts, bailiff steps,
--   INSOLVENCY_OPEN_DATE and BANKRUPTCY_END_DATE for other instances. For
--   Italy they are not sparse — they are absent. On CASES itself the legal
--   columns are 0% filled too: COURT_PROCEDURE, JUDGEMENT_DATE, SERVING_DATE,
--   LEGAL_CLAIM_REASON, STATUTE_BARRED_DATE, DEBT_ENFORCEMENT_NUMBER,
--   DENOUNCEMENT_DATE. So insolvency cannot be measured here at all.
--
-- ⚠ CAT DOES NOT GIVE THIS BOOK EXTRA HISTORY. The usual reason to prefer raw
--   CAT over PROD is PROD's 2014-10-10 collection floor. It does not apply:
--   4034 registrations run 2024-07-21 .. 2025-12-07 and the phase feed starts
--   2024-07-21. This is a 2024+ book. PROD holds the same 48,547 cases.
--
-- ============================================================================
-- THE TWO THINGS MOST LIKELY TO BE MISREAD
-- ============================================================================
-- ⚠ G7  AMICABLE_START IS A PORTFOLIO ONBOARDING STAMP, NOT A CASE EVENT.
--   A002 has only 8 distinct start dates across 48,546 loans, and each one's
--   loan count is exactly a portfolio's size (2024-12-24 = 17,241 = the whole
--   of IT24013A010000; 2025-03-23 = 14,589 = IT24014A010000; and so on).
--   Every loan in a batch is stamped on the day the batch was loaded.
--   → DAYS_IN_AMICABLE is therefore "days from onboarding to first legal
--     action", which is a real and useful number, but it is NOT evidence of
--     a per-loan amicable strategy. Do not describe it as one.
--
-- ⚠ G8  L002 IS STAMPED REPEATEDLY AND THE REPEATS ARE NOT RE-ENTRIES.
--   7,792 of the 17,003 legal loans carry more than one L002 start date, up
--   to 8. Consecutive case_ids share identical date sequences (1182342,
--   1182343 and 1182344 all read A002 2024-12-15, then L002 on 2024-12-16,
--   2025-03-17, 2025-04-14 and 2026-06-23), so these are batch stamps applied
--   to a tranche of loans at once, not one loan bouncing in and out of court.
--   → LEGAL_START is the FIRST L002 date and is the only defensible entry
--     point. The repeats are exposed as LEGAL_STAMP_COUNT rather than being
--     silently collapsed, so anyone can audit the choice.
--   → Do NOT sum per-stamp durations into a "time in legal": that would count
--     the same calendar days up to 8 times.
--
-- ⚠ ONE LOAN IN FIVE NEVER ESCALATED — IT WAS BOUGHT ALREADY IN LEGAL.
--   DAYS_IN_AMICABLE has a spike of 3,234 loans at EXACTLY 1 day, then NOTHING
--   at all from day 2 to day 10 — the next loans are 3 of them on day 11. A
--   gap that clean is a load artefact, not behaviour: these loans were stamped
--   L002 the day after their batch landed, so they arrived in legal
--   proceedings the seller had already started.
--   → ESCALATION_ROUTE separates them. They are 19.020% of the legal
--     population but EUR 294.5m of its EUR 752.6m capital — 39.1% — so
--     folding them into an average drags "time to escalate" down hard
--     (overall median 156 days; 198 for loans that actually escalated).
--   → The cut is at <= 1 day because the data puts it there: days 2-10 are
--     empty, so it is not a tuned threshold and no loan sits on the boundary.
--
-- ============================================================================
-- GUARDS
-- ============================================================================
--   G1 CASES and GROUP_CASE_PHASE are CHANGE-HISTORY feeds. CASES is deduped
--      to the latest version per CASE_ID; the phase feed to distinct
--      (case, code, start_date). 77,285 phase rows -> 76,840 spells.
--   G2 _file_path matched as a LITERAL PREFIX (no leading %) or Snowflake
--      cannot prune and the query scans the whole 6.4bn-row table.
--   G3 ALL extracts are read and unioned. 4034's first extract
--      (20251103T122454, 48,329 cases) is the full load; the eight later ones
--      are DELTAS of 12k-24k cases each. Taking max(_file_path) would return
--      18,798 loans instead of 48,547 — with no error.
--   G4 CASE_ID is unique only within an instance, so 4034 is pinned in the
--      path and carried into CASE_BK for any join to PROD.
--   G5 Container cases (hyphenated CASE_ID) dropped.
--   G6 DELETED / ARCHIVED / UNLINKED phase rows dropped. All three are 0 on
--      this instance today; the guard is here so that stays true.
--   G9 OBSERVATION_END is derived, not hardcoded — the newest phase date in
--      the feed (2026-07-31 today). Open loans are CENSORED there and flagged.
--
-- ⚠ G10 LOAN_TYPE_RAW IS TRUNCATED TO 10 CHARACTERS AT SOURCE. max(length)
--   is exactly 10 across all 133 values, so "CONTO CORR" is conto corrente,
--   "SPESE LEGA" is spese legali, "MUTUO IPOT" is mutuo ipotecario. Some
--   truncations are genuinely ambiguous ("CREDITO A", 3,149 loans) and the
--   same product appears under variant spellings ("MUTUO CHIR" / "MUTUI
--   CHIR"). Report to the data team: the truncation is in the feed, not here.
--
-- ⚠ G11 A QUARTER OF THE ROWS ARE COST LINES, NOT LOANS. SPESE / SPESE LEGALI
--   / SPESE DIVERSE and friends are 12,083 rows (24.9%) but ~1.0% of capital
--   — average EUR 752 against EUR 101,342 for a mutuo. LOAN_TYPE_GROUP
--   returns them as 'Expenses / costs (not a loan)' so they can be excluded
--   from any per-loan average. Leaving them in halves every mean you quote.
--
-- ⚠ G12 MAIN_STATUS_CODE DISAGREES BETWEEN TWO CAT TABLES. CASES says 0
--   ("Registered", 46,474 loans); CASE_STATUS_CHANGE_HISTORY says 64
--   ("On-going", 48,546). Both say 6 ("Completed") for the ~2,073 closed.
--   PROD.DIM_CASE inherits the 0. 0 reads as "no action taken yet", which is
--   plainly false for a book that is 35% in legal — treat it as an unset
--   default. Either way the code adds nothing beyond open/closed here.
--
-- ⚠ LOAN_TYPE_GROUP IS OURS, NOT INTRUM'S. The raw Italian text is Intrum's
--   and is quotable; the grouping below is a reading of it applied by us.
--   It lives in ONE case expression so it is a one-line change to correct.
--
-- ⚠ RAW only. Read-only. Nothing may follow the final semicolon.
-- ============================================================================

set source_system = '4034';
set raw_prefix    = 'data-prod-data-raw-sftp-071269be/intrum/cat.';


-- G1-G5. One row per loan: its latest version across every extract.
with cases as (
    select
        c.case_id                                     as loan_id,
        $source_system || '-' || c.case_id            as case_bk,
        c.long_portfolio_id                           as portfolio_id,
        c.portfolio_sellers_name                      as portfolio_seller,
        upper(trim(c.case_classification))            as loan_type_raw,
        c.is_secured,
        c.is_titled,
        c.product_id,
        c.case_phase                                  as current_case_phase,
        trim(c.main_status_code)                      as main_status_code,
        c.original_capital,
        c.remaining_capital,
        c.registration_date::date                     as registration_date,
        c.default_date::date                          as default_date,
        c.closing_date::date                          as closing_date
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'   -- G2, G3
      and c.case_id not like '%-%'                                       -- G5
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1                                                                -- G1
),

-- G1, G6. One row per genuine phase spell.
spells as (
    select distinct
        g.case_id              as loan_id,
        g.group_phase_code     as phase_code,
        g.start_date::date     as start_date
    from RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE as g
    where g._file_path like $raw_prefix || $source_system || '.%'         -- G2
      and g.group_phase_code is not null
      and g.start_date is not null
      and coalesce(g.deleted,  0) = 0                                     -- G6
      and coalesce(g.archived, 0) = 0
      and coalesce(g.unlinked, 0) = 0
),

-- G9. Derived, never hardcoded: the newest phase date the feed has reached.
horizon as (select max(start_date) as observation_end from spells),

-- G7, G8. First entry into each phase, plus the repeat count kept visible.
phase_dates as (
    select
        loan_id,
        min(iff(phase_code = 'A002', start_date, null))   as amicable_start,
        min(iff(phase_code = 'L002', start_date, null))   as legal_start,
        max(iff(phase_code = 'L002', start_date, null))   as legal_last_stamp,
        count(distinct iff(phase_code = 'L002', start_date, null)) as legal_stamp_count
    from spells
    group by 1
)

select
    c.portfolio_id,
    c.portfolio_seller,
    c.loan_id,
    c.case_bk,

    -- Intrum's own text, truncated by them to 10 chars (G10). Quotable.
    coalesce(c.loan_type_raw, '(no classification)')      as loan_type_raw,

    -- OURS (G11). A reading of the Italian above, not Intrum's taxonomy.
    case
        when c.loan_type_raw is null                       then 'Unclassified'
        when c.loan_type_raw like 'SPESE%'
          or c.loan_type_raw like '%- SPE%'
          or c.loan_type_raw like '9996%'
          or c.loan_type_raw in ('PREMI ASSI','SOPRAVVENI')
                                                           then 'Expenses / costs (not a loan)'
        when c.loan_type_raw like '%MUTU%'
          or c.loan_type_raw like '%- MUT%'                then 'Mortgage (mutuo)'
        when c.loan_type_raw like 'CONTO%'
          or c.loan_type_raw like 'C/C%'
          or c.loan_type_raw like 'CC %'
          or c.loan_type_raw like 'C/CORR%'
          or c.loan_type_raw like 'SALD%'
          or c.loan_type_raw like '%- SCO%'
          or c.loan_type_raw like '9999%'
          or c.loan_type_raw in ('MOVIMENTI','5'' CONTO C')
                                                           then 'Current account / overdraft'
        when c.loan_type_raw like 'ANTICIP%'
          or c.loan_type_raw like '%- ANT%'
          or c.loan_type_raw like 'PORTAFOG%'
          or c.loan_type_raw like '%PORTAF%'
          or c.loan_type_raw like 'FATTURE%'
          or c.loan_type_raw like 'EFFETTO%'
          or c.loan_type_raw = 'AVC'                       then 'Advances / receivables finance'
        when c.loan_type_raw like '%- LEA%'                then 'Leasing'
        when c.loan_type_raw like '%- CAR%'                then 'Cards'
        when c.loan_type_raw like 'FIDEJUS%'
          or c.loan_type_raw like '%- FID%'
          or c.loan_type_raw like 'IMPEGNI%'
          or c.loan_type_raw like 'ESCUSSION%'             then 'Guarantee (fideiussione)'
        when c.loan_type_raw like 'PRESTIT%'
          or c.loan_type_raw like 'CREDITO%'
          or c.loan_type_raw like 'FINANZ%'
          or c.loan_type_raw like 'FINAZ%'
          or c.loan_type_raw like 'FIN.%'
          or c.loan_type_raw like 'SOVVENZION%'
          or c.loan_type_raw like 'SPECIALPRE%'
          or c.loan_type_raw like '%- CRE%'
          or c.loan_type_raw like '%- FIN%'
          or c.loan_type_raw like '%- PRE%'
          or c.loan_type_raw like '%- PAR%'
          or c.loan_type_raw like '%- SOV%'
          or c.loan_type_raw like '%- AGR%'                then 'Loan / financing'
        else                                                    'Other / unmapped'
    end                                                   as loan_type_group,

    -- ⚠ IS_TITLED, PRODUCT_ID AND CASE_PHASE ARE THE SAME FACT AS THE PHASE,
    --   NOT INDEPENDENT ATTRIBUTES. Cross-tabbed 2026-09-15: product_id 7 and
    --   case_phase 2000 partition the book identically (709 never-legal /
    --   16,440 legal), and is_titled=1 is 95.9% legal against 1.2% for
    --   is_titled=0. Do not read "titled loans escalate more" off them — it
    --   is the same column twice. IS_SECURED *is* independent.
    c.is_secured::boolean                                 as is_secured,
    c.is_titled::boolean                                  as is_titled,
    c.current_case_phase,
    c.product_id,

    c.main_status_code,                                                   -- G12
    case c.main_status_code when '0' then 'Registered'
                            when '6' then 'Completed'
                            else '(code not in dictionary)' end
                                                          as main_status_description,

    c.original_capital,
    c.remaining_capital,
    c.registration_date,
    c.default_date,
    c.closing_date,
    c.closing_date is not null                            as is_closed,

    -- The journey. G7: amicable_start is the batch onboarding date.
    p.amicable_start,
    p.legal_start,
    p.legal_last_stamp,
    coalesce(p.legal_stamp_count, 0)                      as legal_stamp_count,   -- G8
    p.legal_start is not null                             as reached_legal,

    case when p.legal_start is not null then 'Legal (L002)'
         when p.amicable_start is not null then 'Amicable only (A002)'
         else '(no phase row)' end                        as phase_reached,

    -- The distinction that makes every duration below readable. See the
    -- day-1 spike note in the header.
    case
        when p.legal_start is null then 'Never legal'
        when datediff('day', p.amicable_start, p.legal_start) <= 1
             then 'Arrived in legal'
        else 'Escalated to legal'
    end                                                   as escalation_route,

    h.observation_end,                                                    -- G9

    -- Onboarding -> first legal action. Fully observed for loans that
    -- escalated; for the rest this is time watched WITHOUT escalating, which
    -- is a different quantity — hence the flag below.
    datediff('day', p.amicable_start,
             coalesce(p.legal_start, c.closing_date, h.observation_end))
                                                          as days_in_amicable,
    p.legal_start is null                                 as amicable_is_censored,

    -- Time in legal OBSERVED SO FAR. ⚠ 96% of legal loans are still open, so
    -- this is a duration-to-date, not a time-to-resolution. Never quote it as
    -- "how long a legal case takes".
    datediff('day', p.legal_start,
             coalesce(c.closing_date, h.observation_end)) as days_in_legal,
    (p.legal_start is not null and c.closing_date is null) as legal_is_censored

from cases as c
left join phase_dates as p on p.loan_id = c.loan_id        -- G6: keep loans with no phase row
cross join horizon as h
order by c.portfolio_id, c.loan_id;
