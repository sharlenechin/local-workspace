-- How old the debt is, per deal: years from the borrower's default to today.
-- GRAIN  one row per deal, keyed VEHICLE-ID as in deals_we_own.sql.
-- RUN    mise run sql -- work/workshop/queries/debt_age.sql
-- SOURCE PROD NPL_COMMON only: DIM_CASE for the default date, and the case snapshot for
--        the case-to-deal link, which DIM_CASE does not carry.
--
-- WHY THIS EXISTS. The attribute grids answer only whether a deal HAS a default date, not
-- what it says. `debt_age` scores as found on 1,042 of the 1,043 modellable deals, which
-- tells us nothing about whether that debt is three years old or twenty. This measures it.
--
-- NOT THE SAME AS HOW LONG WE HAVE HELD IT. Default is the borrower's event, years before
-- we bought in most books. The holding period is capex_date in deals_we_own.sql; the two
-- differ by a decade on the older Heimdall books.
--
-- A QUARTER OF CASES HAVE NO DEFAULT DATE. They are excluded, not counted as age zero,
-- so a deal's figure describes the cases that carry one. cases_with_default_date says how
-- many that was, so a thin denominator is visible rather than hidden. Measured 2026-11-04.
WITH
    batch AS (

        SELECT
            b.batch_sk,
            -- Same id rule as deals_we_own.sql: Heimdall under Intrum's id, the rest Atlas.
            COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) || '-' || IFF(
                COALESCE(b.deal_source_bk, LEFT(p.portfolio_bk, 3)) = 'HEI',
                b.servicer_parent_portfolio_bk,
                SUBSTR(p.portfolio_bk, 5, 7)
            ) AS deal_id
        FROM prod.npl_common.dim_batch AS b
        LEFT JOIN prod.npl_common.dim_portfolio AS p
            ON p.portfolio_sk = b.portfolio_sk
),

    case_deal AS (

        SELECT DISTINCT
            s.case_id,
            b.deal_id
        FROM prod.npl_common.fct_case_snapshot_daily AS s
        INNER JOIN batch AS b
            ON b.batch_sk = s.batch_sk
)

SELECT
    d.deal_id,
    COUNT(*) AS cases_with_default_date,
    -- Median, not mean: a handful of 1970 placeholder dates would drag a mean by years.
    ROUND(MEDIAN(DATEDIFF('day', c.default_date, CURRENT_DATE)) / 365.25, 5)
        AS median_debt_age_years
FROM case_deal AS d
INNER JOIN prod.npl_common.dim_case AS c
    ON c.case_id = d.case_id
    AND c.is_current_flag
WHERE c.default_date IS NOT NULL
    -- Guards, not filters of convenience. A default cannot predate consumer credit in
    -- these markets, and cannot be in the future; both appear in this column.
    AND c.default_date BETWEEN '1980-01-01' AND CURRENT_DATE
GROUP BY 1
ORDER BY 1;
