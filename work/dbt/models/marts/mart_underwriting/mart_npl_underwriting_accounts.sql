/*
UNDERWRITING. ONE ROW PER LOAN (CASE_BK) -- the static picture of an account at
the point we bought it, in the shape the pricing pipeline expects.

BUILT FOR npl-underwriting, NOT FOR THE SERVICING DASHBOARD. The servicing marts
beside this one answer "how is the book performing this month". This one answers
"what did we buy", which is a different question with a different grain: one row
per loan, no month, no time series. Collections over time live in
mart_npl_underwriting_collections.

⚠⚠ CASE_BK IS THE KEY, NOT CASE_SK. DIM_CASE is an SCD2 (154m versions for 22.5m
loans) and every fact carries the versioned CASE_SK, so 40% of loans change
version inside a year. Joining anything to this model on CASE_SK silently drops
the restated ones. CASE_SK is carried only so a consumer can resolve that
version's point-in-time attributes; it is NOT a join key.

⚠⚠ SCOPED TO LOANS ON BOOK AT EACH PORTFOLIO'S LATEST FILE. 21,883,499 of the
22,531,451 current loans. The other ~648k are not on any portfolio's newest file
-- closed, sold on, or absent -- and are EXCLUDED, because an underwriting
account list describes what we hold. ⚠ That is the wrong scope for a liquidation
curve, which needs the closed ones too; use the collections model for that.

⚠⚠⚠ TWO REQUESTED COLUMNS ARE TOO THIN TO PRICE ON. Measured 2026-09-29 across
the 21,883,499 loans in scope:
    portfolio_bk / seller / servicer / acquisition_date   ~100%
    batch_bk                                              99.84%
    first_default_date                                    97.58%
    registration_date                                     89.42%
    original_principal                                    14.93%   <-- thin
    origination_date                                       4.72%   <-- very thin
    registration_balance                                  ~20.98%  <-- thin
⚠ ORIGINATION_DATE IS 4.72% POPULATED and there is no usable substitute in the
warehouse. DIM_CASE also carries DERIVED_ORIGINATION_DATE at 99.27%, but its own
column comment reads "placeholder for future use" and it is suspected of being
DEFAULT_DATE minus 36 months -- the inverse of the rule that builds
DERIVED_DEFAULT_DATE. It is DELIBERATELY NOT USED here. Verify it before anyone
reaches for it.
⚠ The asset index (DEV.ASSET_INDEX, brocc-sandbox) holds the seller's own
origination and cut-off figures, which is the real fix -- but its bridge to our
loan ids reaches only 7.55% of loans today.

⚠⚠ REGISTRATION_BALANCE IS NOT THE BALANCE THE SERVICER RECORDED AT REGISTRATION.
Nothing stores that. It is the outstanding total from the monthly case snapshot
at the month-end of the registration date, and it exists only where that month
falls inside our file coverage -- so ~21% of loans. The median book has just 11
months of snapshot history, because a book enters the snapshot when files start
arriving, not when the loan was registered. HAS_REGISTRATION_BALANCE_FLAG
separates "nothing was recorded" from "no registration date".

⚠⚠ THE SNAPSHOT JOIN IS ON CASE_BK AND THIS IS LOAD-BEARING. Keying it on
CASE_SK -- the obvious thing, since that is what the snapshot carries -- matches
today's version against a past month and finds almost nothing. Measured
2026-09-28 on HEI-ES25001-U01/2512: CASE_SK found 1,070 balances where CASE_BK
finds 1,026,764, a 960x undercount that reads as missing history rather than as
an error. Resolving the durable key costs a join to DIM_CASE; that is the price.

⚠ ACQUISITION_DATE IS BROCC'S PURCHASE (DIM_PORTFOLIO.CAPEX_DATE), inherited from
the portfolio and stamped onto every loan in it -- it is not a fact about this
loan. It clusters hard: every book is dated 2025-12-01..2026-08-01 and 154 of 263
share 2025-12-01, so it is useless as a vintage. Use REGISTRATION_YEAR for that.
⚠ LEGACY_ACQUISITION_DATE is the batch's date -- when the book was acquired from
the ORIGINAL SELLER, which means different things per deal source: Heimdall is
Intrum buying from the seller, Loki is Cerberus/Intrum, Legacy ES/IT is Cerberus.
It is NULL on all Gescobro books (5 of 5 batches), which is a feed gap rather
than an absence of purchase -- those books were bought 2026-05..2026-07.

⚠ FIRST_DEFAULT_DATE IS THE SERVICER'S OWN DEFAULT_DATE, not the derived one.
Its range is dirty at both ends (1995-10-31 .. 2026-04-03), so bound it before
bucketing. The asset index disagrees with it by a mean of 8 days on one book and
~1,273 days on another; nobody has established which the deals were priced on.
*/

WITH latest_file AS (
    -- ⚠ EACH PORTFOLIO'S OWN NEWEST MONTH, not one global date: books report on
    -- different calendars, and a global MAX would drop every book that reports
    -- late.
    SELECT
        portfolio_sk,
        MAX(date_day)                                  AS latest_day
    FROM {{ ref('fct_npl_case_snapshot_daily') }}
    GROUP BY 1
),

on_book AS (
    -- The loans we hold, with the book and batch they sat in on that file.
    -- ⚠ ANY_VALUE COLLAPSES THE 2,321 LOANS THAT SIT IN TWO PORTFOLIOS on the
    -- same day. That is a deliberate loss: this model is one row per loan, and
    -- a loan in two books has no single answer. PORTFOLIO_COUNT flags them.
    SELECT
        s.case_sk,
        ANY_VALUE(s.portfolio_sk)                      AS portfolio_sk,
        ANY_VALUE(s.batch_sk)                          AS batch_sk,
        ANY_VALUE(s.reporting_system_sk)               AS reporting_system_sk,
        ANY_VALUE(s.legal_buyer_sk)                    AS legal_buyer_sk,
        COUNT(DISTINCT s.portfolio_sk)                 AS portfolio_count,
        MAX(s.date_day)                                AS latest_snapshot_day
    FROM {{ ref('fct_npl_case_snapshot_daily') }} AS s
    INNER JOIN latest_file AS l
        ON l.portfolio_sk = s.portfolio_sk
        AND l.latest_day = s.date_day
    GROUP BY 1
),

case_current AS (
    SELECT
        case_bk,
        case_sk,
        case_id,
        registration_date::DATE                        AS registration_date,
        origination_date::DATE                         AS origination_date,
        default_date::DATE                             AS first_default_date,
        closing_date::DATE                             AS closing_date,
        closing_code,
        original_principal,
        secured_flag,
        status_code,
        as_of_ts                                       AS source_updated_at
    FROM {{ ref('dim_npl_case') }}
    WHERE is_current_flag = TRUE
),

registration_balance AS (
    -- ⚠⚠ KEYED ON CASE_BK -- see the header. The snapshot carries only CASE_SK,
    -- so the durable key has to be resolved through the case dimension.
    -- ⚠ RESTRICTED TO THE MONTH-ENDS THAT ARE ACTUALLY REGISTRATION MONTHS,
    -- because the snapshot is 1.47bn rows and an unfiltered scan is the most
    -- expensive read in this layer.
    -- ⚠ SUM, not ANY_VALUE: a loan exposed in two books owes the total of both.
    SELECT
        dv.case_bk,
        s.date_day,
        SUM(s.outstanding_principal)                   AS balance_principal,
        SUM(s.outstanding_total)                       AS balance_total
    FROM {{ ref('fct_npl_case_snapshot_daily') }} AS s
    INNER JOIN {{ ref('dim_npl_case') }} AS dv
        ON dv.case_sk = s.case_sk
    WHERE s.date_day IN (SELECT DISTINCT LAST_DAY(registration_date)
                         FROM case_current
                         WHERE registration_date IS NOT NULL)
    GROUP BY 1, 2
)

SELECT
    -- ---- keys -------------------------------------------------------------
    -- ⚠⚠ JOIN ON THIS. Stable across restatement.
    c.case_bk,
    -- ⚠ A VERSION key. Use it only to resolve that version's attributes.
    c.case_sk,
    c.case_id,

    -- ---- the book it sits in ----------------------------------------------
    p.portfolio_bk                                     AS portfolio_bk,
    b.batch_bk                                         AS batch_bk,
    -- ⚠ ABOVE 1 means the loan sits in two books and PORTFOLIO_BK is one of two
    -- answers. 2,321 loans.
    o.portfolio_count,
    COALESCE(co.country_name, d.country_id, 'Unknown') AS country_name,
    COALESCE(d.country_id, 'Unknown')                  AS country_code,
    COALESCE(d.seller_name, 'Unknown')                 AS seller_name,
    COALESCE(ds.deal_source_name, 'Unknown')           AS deal_source,
    COALESCE(d.deal_alias, d.deal_bk, 'Unknown')       AS deal,
    -- ⚠⚠ THE COMPANY, NOT THE PLATFORM. REPORTING_SYSTEM_NAME is an Intrum
    -- platform ('CAT Fenix'), so a book migrated between two of Intrum's own
    -- systems would read as two different servicers. The platform is carried
    -- separately below because it is what CASE_BK is built from.
    IFF(rs.servicer_name = LOWER(rs.servicer_name),
        INITCAP(rs.servicer_name), rs.servicer_name)   AS servicer_name,
    -- ⚠ NOT A COMPANY. Codes 7006 and 7010 are both 'CAT Scale'.
    rs.reporting_system_name                           AS servicer_platform,
    COALESCE(lb.legal_buyer_name, 'Unknown')           AS legal_buyer_name,
    -- ⚠ BROCC'S ECONOMIC STAKE IN THE VEHICLE, often below 1, and STALE on the
    -- legacy-platform loans of 13 portfolios -- the migrated platform picked up
    -- a share change the legacy one did not. Do not weight silently.
    lb.ownership_share,
    p.currency_id                                      AS portfolio_currency,

    -- ---- the dates underwriting asked for ---------------------------------
    -- ⚠ THE LOAN'S OWN DATE, and the only one here that is. 89.42%.
    c.registration_date,
    DATE_TRUNC('MONTH', c.registration_date)::DATE     AS registration_month,
    YEAR(c.registration_date)                          AS registration_year,
    -- ⚠ 4.72% POPULATED. See the header before using it.
    c.origination_date,
    YEAR(c.origination_date)                           AS origination_year,
    -- ⚠ THE SERVICER'S OWN DEFAULT DATE, 97.58%. Dirty at both ends.
    c.first_default_date,
    -- ⚠ THE PORTFOLIO'S DATE, inherited. Not a vintage -- see the header.
    p.capex_date                                       AS acquisition_date,
    -- ⚠ THE BATCH'S DATE. Whose purchase it was depends on deal source.
    bt.legacy_capex_date::DATE                         AS legacy_acquisition_date,
    -- ⚠ NEGATIVE where the servicer registered the loan BEFORE we bought the
    -- book, which is the normal shape. Positive means it was registered after.
    DATEDIFF('MONTH', c.registration_date, p.capex_date)
                                                       AS months_registered_before_acquisition,

    -- ---- money -------------------------------------------------------------
    -- ⚠⚠ THE SNAPSHOT BALANCE AT THE REGISTRATION MONTH, ~21% populated, NOT a
    -- figure the servicer recorded at registration. See the header.
    rb.balance_principal                               AS registration_balance_principal,
    rb.balance_total                                   AS registration_balance_total,
    -- ⚠ THE SERVICER'S RECORDED ORIGINAL FIGURE, 14.93%. NOT a balance as at
    -- the origination date, and not comparable with the snapshot balances above.
    c.original_principal,

    -- ---- state -------------------------------------------------------------
    IFF(c.closing_date IS NULL, 'OPEN', 'CLOSED')      AS case_status,
    c.closing_date,
    -- ⚠ POPULATED on 9.26m loans across 47 codes, and NOTHING IN THE WAREHOUSE
    -- DECODES IT. CLOSING_DESCRIPTION and CLOSING_CATEGORY are 100% NULL.
    c.closing_code,
    c.secured_flag,
    c.status_code,

    -- ---- flags -------------------------------------------------------------
    c.registration_date IS NOT NULL                    AS has_registration_date_flag,
    c.origination_date IS NOT NULL                     AS has_origination_date_flag,
    c.first_default_date IS NOT NULL                   AS has_first_default_date_flag,
    -- ⚠ FALSE means no snapshot covered that month, NOT that the balance was
    -- zero. Separates "unknown" from "nothing owed".
    rb.case_bk IS NOT NULL                             AS has_registration_balance_flag,

    -- ---- provenance ---------------------------------------------------------
    o.latest_snapshot_day,
    -- ⚠ WHEN THE WAREHOUSE LAST TOUCHED THE RECORD, not when anything happened.
    c.source_updated_at
FROM on_book AS o
INNER JOIN case_current AS c
    ON c.case_sk = o.case_sk
-- Every dimension LEFT joined: an orphan key must read 'Unknown' rather than
-- drop the loan. PORTFOLIO_SK = '-1' is a real sentinel and is NOT in
-- DIM_NPL_PORTFOLIO.
LEFT JOIN {{ ref('dim_npl_portfolio') }} AS p
    ON p.portfolio_sk = o.portfolio_sk
LEFT JOIN {{ ref('dim_npl_batch') }} AS b
    ON b.batch_sk = o.batch_sk
LEFT JOIN {{ ref('dim_npl_batch') }} AS bt
    ON bt.batch_sk = o.batch_sk
LEFT JOIN {{ ref('dim_npl_deal') }} AS d
    ON d.deal_id = p.deal_id
LEFT JOIN {{ ref('dim_npl_deal_source') }} AS ds
    ON ds.deal_source_bk = d.deal_source_bk
LEFT JOIN {{ ref('dim_npl_reporting_system') }} AS rs
    ON rs.reporting_system_sk = o.reporting_system_sk
LEFT JOIN {{ ref('dim_npl_legal_buyer') }} AS lb
    ON lb.legal_buyer_sk = o.legal_buyer_sk
-- ⚠ JOIN ON ISO_ALPHA2_CODE. The facts carry 'ES', 'FI', 'GB' in COUNTRY_ID
-- while DIM_COUNTRY.COUNTRY_ID is a hash key, so the natural join matches zero
-- rows and leaves every country name NULL with no error.
LEFT JOIN {{ ref('dim_country') }} AS co
    ON co.iso_alpha2_code = d.country_id
LEFT JOIN registration_balance AS rb
    ON rb.case_bk = c.case_bk
    AND rb.date_day = LAST_DAY(c.registration_date)
