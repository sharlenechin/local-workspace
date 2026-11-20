-- ============================================================================
-- SCOPED AMOUNT MATCH -- one row per bridged portfolio, verified against truth.
-- Measured 2026-10-21.
--
-- ⚠⚠ THIS SUPERSEDES balance_probe_negative_result.sql, WHICH WAS A BAD TEST.
-- That query compared our principal_at_cutoff to CAT's principal_at_cutoff
-- (which matches ZERO rows; the right column is original_capital) and matched
-- globally across 20m CAT cases instead of scoping to the book's portfolio.
-- Corrected and scoped, amount matching reaches 99.7-100% precision on the
-- German books -- including DE25020, which no reference rule reaches at all.
--
-- ⚠ PRECISION VARIES PER BOOK AND MUST BE MEASURED. ES25021 produced 118
-- unambiguous matches and every checkable one was WRONG. Never carry a sibling
-- book's precision across.
--
-- ⚠ TAKE UNAMBIGUOUS MATCHES ONLY -- one candidate per case of ours. Round
-- amounts collide freely; an ambiguous match is not a match.
--
-- ⚠ Needs the book's CAT long_portfolio_id, which cannot be derived (our
-- SE25008 is SE25018D020000 there). Learned here from the bridge itself; for an
-- unbridged book it has to be asked for.
-- ============================================================================
WITH truth AS (
    SELECT portfolio_id, case_id, servicer_case_id::string AS their_case
    FROM dev.asset_index.case_bridge
    WHERE match_status = 'matched' AND servicer_case_id IS NOT NULL
),

-- Which CAT portfolio holds each of our books, learned from the bridge itself.
book_portfolio AS (
    SELECT t.portfolio_id, c.long_portfolio_id, COUNT(*) AS n,
           ROW_NUMBER() OVER (PARTITION BY t.portfolio_id ORDER BY COUNT(*) DESC) AS rn
    FROM truth AS t
    INNER JOIN prod_raw.hyperion_intrum_cat.cases AS c
        ON c.case_id::string = t.their_case
    WHERE c.long_portfolio_id IS NOT NULL
    GROUP BY t.portfolio_id, c.long_portfolio_id
),

scope AS (SELECT portfolio_id, long_portfolio_id FROM book_portfolio WHERE rn = 1),

-- Their side, one row per case, scoped to that portfolio.
theirs AS (
    SELECT s.portfolio_id, c.case_id::string AS their_case,
           ROUND(MAX(c.original_capital), 2) AS amt
    FROM scope AS s
    INNER JOIN prod_raw.hyperion_intrum_cat.cases AS c
        ON c.long_portfolio_id = s.long_portfolio_id
    WHERE c.original_capital IS NOT NULL
    GROUP BY s.portfolio_id, c.case_id::string
),

ours AS (
    SELECT portfolio_id, case_id, ROUND(principal_at_cutoff, 2) AS amt
    FROM dev.asset_index.cases
    WHERE principal_at_cutoff IS NOT NULL
),

matched AS (
    SELECT o.portfolio_id, o.case_id, t.their_case,
           COUNT(*) OVER (PARTITION BY o.portfolio_id, o.case_id) AS candidates
    FROM ours AS o
    INNER JOIN theirs AS t
        ON t.portfolio_id = o.portfolio_id AND t.amt = o.amt
)

SELECT
    m.portfolio_id,
    COUNT(DISTINCT m.case_id) AS our_cases_matched,
    SUM(CASE WHEN m.candidates = 1 THEN 1 ELSE 0 END) AS unambiguous,
    SUM(CASE WHEN m.candidates = 1 AND m.their_case = tr.their_case THEN 1 ELSE 0 END) AS unambig_correct,
    SUM(CASE WHEN m.candidates = 1 AND tr.their_case IS NOT NULL
             AND m.their_case <> tr.their_case THEN 1 ELSE 0 END) AS unambig_WRONG
FROM matched AS m
LEFT JOIN truth AS tr
    ON tr.portfolio_id = m.portfolio_id AND tr.case_id = m.case_id
GROUP BY m.portfolio_id
ORDER BY unambiguous DESC;
