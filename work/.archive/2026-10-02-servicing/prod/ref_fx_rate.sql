-- ============================================================================
-- ref_fx_rate — REFERENCE: one row per currency pair per month-end.
-- GRAIN: one row per (DATE_DAY, BASE_CURRENCY, QUOTE_CURRENCY, RATE_TYPE).
-- ============================================================================
-- The missing piece for every money total in this folder. Nearly every other
-- file warns that CURRENCY_ID is part of its grain and that money must not be
-- summed across currencies unconverted — this is what you convert with.
--
--   Extension : open and Run All
--   Terminal  : mise run sql -- work/servicing/prod/ref_fx_rate.sql
--   Notebook  : datalake.q("servicing/prod/ref_fx_rate")
--
-- ---------------------------------------------------------------------------
-- GRAIN verified 2026-09-09: COMMON.FCT_EXCHANGE_RATE_MONTHLY has 2,288 rows
-- and 2,288 distinct (DATE_DAY, BASE_CURRENCY, QUOTE_CURRENCY, RATE_TYPE).
-- Unique, no dedupe needed.
--
-- ⚠ USE RATE_TYPE = 'PMI'. 'FIXED' IS NOT AN ALTERNATIVE BASIS.
-- Measured 2026-09-09 — the table has exactly 22 (base, quote, rate_type)
-- combinations, and FIXED is only ever the identity self-pair:
--     FIXED : EUR->EUR and SEK->SEK only, both rate 1.0
--     PMI   : every real cross rate — EUR-> AUD CHF CZK DKK GBP HUF NOK PLN
--             SEK USD, and SEK-> the same set plus EUR
-- So filtering to FIXED returns one useless self-row and silently converts
-- nothing. That is why $rate_type defaults to PMI. FIXED is not a
-- "fixed-rate basis" to choose between; treat it as a degenerate row.
--
-- ⚠ ONLY TWO BASE CURRENCIES EXIST: EUR AND SEK.
-- You cannot convert an arbitrary pair directly. To get DKK to EUR you take
-- the EUR-based PMI row for DKK and invert it, which is what RATE_TO_BASE
-- below does. Anything not in the ten quoted currencies is not convertible
-- from this table at all.
--
-- ⚠ THE BASE CURRENCY ITSELF HAS NO PMI ROW.
-- There is no EUR->EUR PMI rate, so a plain join drops the rows already in
-- $to_currency — which are usually the largest block. The self-rate is
-- unioned in below at 1.0 so a join covers every currency. Do not remove it.
--
-- ⚠ THE RATE IS ALREADY THE MULTIPLIER. DO NOT INVERT IT.
-- The column names say BASE_CURRENCY / QUOTE_CURRENCY, which by the usual
-- market convention would mean "units of quote per one base". It is the
-- OTHER WAY ROUND here: the value is units of BASE per one unit of QUOTE, so
-- you multiply a foreign amount by it directly.
--
-- Verified against the raw July-2026 EUR-base PMI rows on 2026-09-09:
--     GBP 1.17109    SEK 0.09053    HUF 0.00278    CHF 1.08043
-- One GBP really is worth more than one EUR and one SEK far less, so these
-- are EUR per unit of the foreign currency. Inverting them values SEK 32.2m
-- at EUR 356m instead of EUR 2.9m — a 122x overstatement that looks
-- plausible enough on a chart to ship.
--
-- ⚠ WHICH COLUMN YOU PICK CHANGES THE ANSWER.
--   ULTIMO_VALUE  — the rate AT month end. Use for BALANCES and any stock
--                   figure (outstanding, carrying amount): they are measured
--                   at a point in time.
--   MONTHLY_AVG   — the average across the month. Use for FLOWS accumulated
--                   over the month (collections, fees): converting a whole
--                   month of receipts at the closing rate misstates them.
--   YTD_AVG       — year-to-date average, for cumulative reporting.
-- Both are exposed; there is no single correct one.
--
-- ⚠ COVERAGE STOPS AT 2026-08-31 (and starts 2018-01-31).
-- A join for a month outside that range yields NULL, and NULL * amount is
-- NULL — so an unguarded conversion silently drops rows rather than
-- erroring. Check IS_RATE_AVAILABLE before you rely on a converted total.
--
-- ⚠ IS_DIRECT = false MEANS THE RATE WAS DERIVED, NOT OBSERVED.
-- It is carried through rather than hidden, so you can exclude derived rates
-- if the report needs observed ones only.
--
-- No row cap: 2,288 rows is the whole table.
-- ============================================================================

-- Leave this as PMI. See the warning above: FIXED converts nothing.
set rate_type = 'PMI';

-- The currency you want everything expressed IN. Must be EUR or SEK.
set to_currency = 'EUR';

set date_from = '2018-01-31';
set date_to   = '2026-12-31';


with rates as (
    select
        date_day                as month_end,
        base_currency,
        quote_currency,
        rate_type,
        monthly_avg,
        ultimo_value,
        ytd_avg,
        observation_count,
        is_direct,
        source
    from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    where rate_type = $rate_type
      and date_day >= $date_from::date
      and date_day <= $date_to::date
      and base_currency = $to_currency
      -- Drop any self-pair from the source; it is re-added below at 1.0 so
      -- the identity row is present regardless of $rate_type.
      and quote_currency <> $to_currency

    union all

    -- The identity row: amounts already in $to_currency need a rate of 1, and
    -- PMI has no self-pair. Without this they join to NULL and vanish.
    select
        date_day, base_currency, quote_currency, rate_type,
        1 as monthly_avg, 1 as ultimo_value, 1 as ytd_avg,
        observation_count, is_direct, source
    from PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    where base_currency  = $to_currency
      and quote_currency = $to_currency
      and date_day >= $date_from::date
      and date_day <= $date_to::date
)

select
    r.month_end,
    r.base_currency,                        -- the target: $to_currency
    r.quote_currency                        as from_currency,
    cu.currency_name                        as from_currency_name,
    cu.minor_unit                           as from_currency_minor_unit,
    r.rate_type,

    -- ---- as published: units of QUOTE per one unit of BASE ---------------
    r.ultimo_value,                         -- point-in-time: use for BALANCES
    r.monthly_avg,                          -- period average: use for FLOWS
    r.ytd_avg,

    -- ---- the same values, named so the direction is unambiguous ---------
    -- NOT inverted — see the warning in the header. Multiply an amount in
    -- FROM_CURRENCY by one of these to land in $to_currency. nullif turns a
    -- zero rate into NULL rather than a silently wrong 0.
    nullif(r.ultimo_value, 0)               as rate_to_base_ultimo,
    nullif(r.monthly_avg, 0)                as rate_to_base_monthly_avg,
    nullif(r.ytd_avg, 0)                    as rate_to_base_ytd_avg,

    -- ---- trust signals ---------------------------------------------------
    r.is_direct,                            -- false = derived, not observed
    r.observation_count,
    r.source,
    r.ultimo_value is not null
        and r.ultimo_value <> 0             as is_rate_available

from rates as r
left join PROD.COMMON.DIM_CURRENCY as cu
    on cu.currency_alpha_code = r.quote_currency
order by r.month_end desc, r.quote_currency

-- Converting a foreign balance to $to_currency, as a pattern:
--
--   select l.case_bk, l.currency_id, l.outstanding_total,
--          l.outstanding_total * f.rate_to_base_ultimo as outstanding_eur
--   from <a loan-level file> as l
--   left join ( <this query> ) as f
--          on  f.from_currency = l.currency_id
--          and f.month_end     = l.as_of_month_end
--   -- The identity row is included, so rows already in $to_currency get a
--   -- rate of 1 and are NOT dropped. A NULL rate now means genuinely
--   -- unconvertible — check it rather than coalescing it to 1.
