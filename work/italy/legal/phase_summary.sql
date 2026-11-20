-- ============================================================================
-- phase_summary — the funnel in one table: how many Italian loans reached the
-- legal phase, how they got there, and how long each step took, by loan type.
--
--   RUN      mise run sql -- work/italy/legal/phase_summary.sql
--            datalake.q("work/italy/legal/phase_summary", convert=False)
--   GRAIN    one row per (LOAN_TYPE_GROUP, ESCALATION_ROUTE). Totals row last.
--   RUNTIME  ~2 minutes.  Money is EUR.
--
-- ⚠ THIS FILE REPEATS loan_phase_history.sql's SCOPE CTEs ON PURPOSE so it
--   runs standalone. loan_phase_history.sql is the authority — every guard,
--   every caveat and the full reasoning live in its header. READ THAT FIRST.
--   If you change a guard, change it in both.
--
-- THE THREE NUMBERS PEOPLE GET WRONG, IN SHORT:
--   1 Every loan starts in A002 and the only transition is A002 -> L002.
--     There is no legal sub-phase in this feed and no insolvency data at all.
--   2 A002's start date is the day the BATCH was loaded, not a loan event.
--   3 "Days in legal" is censored: 98.265% of legal loans are still open, so
--     it measures how long ago they entered, not how long the process takes.
--     MEDIAN_DAYS_IN_LEGAL_CLOSED is the only uncensored figure here, and it
--     rests on just 295 loans.
--
-- ⚠ RAW only. Read-only. Nothing may follow the final semicolon.
-- ============================================================================

set source_system = '4034';
set raw_prefix    = 'data-prod-data-raw-sftp-071269be/intrum/cat.';


with cases as (
    select
        c.case_id                          as loan_id,
        upper(trim(c.case_classification)) as loan_type_raw,
        c.original_capital,
        c.closing_date::date               as closing_date
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'
      and c.case_id not like '%-%'
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1
),

spells as (
    select distinct g.case_id as loan_id, g.group_phase_code as phase_code,
           g.start_date::date as start_date
    from RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE as g
    where g._file_path like $raw_prefix || $source_system || '.%'
      and g.group_phase_code is not null
      and g.start_date is not null
      and coalesce(g.deleted, 0) = 0
      and coalesce(g.archived, 0) = 0
      and coalesce(g.unlinked, 0) = 0
),

horizon as (select max(start_date) as observation_end from spells),

phase_dates as (
    select loan_id,
           min(iff(phase_code = 'A002', start_date, null)) as amicable_start,
           min(iff(phase_code = 'L002', start_date, null)) as legal_start
    from spells group by 1
),

loans as (
    select
        c.loan_id,
        c.original_capital,
        c.closing_date,
        p.amicable_start,
        p.legal_start,
        h.observation_end,
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
        end as loan_type_group,
        case
            when p.legal_start is null then 'Never legal'
            when datediff('day', p.amicable_start, p.legal_start) <= 1
                 then 'Arrived in legal'
            else 'Escalated to legal'
        end as escalation_route
    from cases as c
    left join phase_dates as p on p.loan_id = c.loan_id
    cross join horizon as h
),

book as (
    select count(*) as n_loans_total, sum(original_capital) as capital_total
    from loans
)

select
    loan_type_group,
    escalation_route,
    count(*)                                            as n_loans,
    sum(original_capital)                               as original_capital_eur,
    -- ⚠ Divided by the BOOK totals from `book`, never by a window over the
    --   result: ROLLUP adds subtotal rows, so `sum(...) over ()` counts the
    --   book three times and every share comes out at a third of the truth.
    count(*) / max(b.n_loans_total)                     as pct_of_loans,
    sum(original_capital) / max(b.capital_total)        as pct_of_capital,

    -- Onboarding -> first legal action. Meaningful only on the
    -- 'Escalated to legal' rows; 'Arrived in legal' is 1 day by definition
    -- and 'Never legal' is time watched without escalating.
    median(datediff('day', amicable_start, legal_start)) as median_days_to_legal,
    avg(datediff('day', amicable_start, legal_start))    as mean_days_to_legal,

    -- ⚠ CENSORED. Counts from entry to closure OR to the feed horizon,
    --   whichever comes first, and 98.265% of these loans are still open.
    median(datediff('day', legal_start,
                    coalesce(closing_date, observation_end)))
                                                        as median_days_in_legal_todate,

    -- The only uncensored duration: loans that entered legal AND closed.
    count(iff(legal_start is not null and closing_date is not null, 1, null))
                                                        as n_closed_in_legal,
    median(iff(legal_start is not null and closing_date is not null,
               datediff('day', legal_start, closing_date), null))
                                                        as median_days_in_legal_closed

from loans
cross join book as b
group by rollup (loan_type_group, escalation_route)
order by loan_type_group nulls last, escalation_route nulls last;
