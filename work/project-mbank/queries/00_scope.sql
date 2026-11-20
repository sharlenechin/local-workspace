-- mBank books: what Intrum's own report (PAM) says we bought, beside what the case feed holds.
-- GRAIN   one row per (deal, CAT instance). A deal on no instance still gets a row.
-- RUN     mise run sql -- work/project-mbank/queries/00_scope.sql
-- WHY     Every extract in this folder is checked against this: case counts, the balance
--         at purchase and the capex date come from PAM, the authority on what was bought.
-- ⚠ PAM's statics (ACQCASES, ACQUISITIONPRINCIPAL) repeat on every month row of every
--   segment, so they are MAX per segment and only then summed across segments.
-- ⚠ CASES is a change history and case_id is unique only within one instance, so cases
--   are counted DISTINCT per instance, which is read off _file_path.
SET deals      = 'PL19009,PL19017,PL20015,PL20020,PL21024,PL23003';
SET raw_prefix = 'data-prod-data-raw-sftp-071269be/intrum/cat.%';

WITH
    deals_asked_for AS (

        SELECT
            TRIM(value::STRING) AS deal
        FROM TABLE(SPLIT_TO_TABLE($deals, ','))
),

    pam_segments AS (

        SELECT
            p.portfolioid AS deal,
            p.combined_ref,
            MAX(p.acqcases) AS acq_cases,
            MAX(p.acquisitionprincipal) AS acq_principal,
            MAX(p.currency) AS currency
        FROM raw.hyperion_intrum_pam.pam AS p
        WHERE p._file_path = (
                SELECT MAX(_file_path)
                FROM raw.hyperion_intrum_pam.pam
                WHERE _file_path LIKE '%/pam.pam.pam.2%'
            )
            AND p.pmode_name = 'Real'
            AND COALESCE(p.is_ownership_change, 0) = 0
            AND p.portfolioid IN (SELECT deal FROM deals_asked_for)
        GROUP BY 1, 2
),

    pam AS (

        SELECT
            deal,
            COUNT(*) AS pam_segments,
            SUM(acq_cases) AS pam_cases,
            SUM(acq_principal) AS pam_principal,
            MAX(currency) AS pam_currency
        FROM pam_segments
        GROUP BY 1
),

    cat AS (

        SELECT
            LEFT(long_portfolio_id, 7) AS deal,
            SPLIT_PART(_file_path, '.', 2) AS instance,
            COUNT(DISTINCT case_id) AS cat_cases,
            COUNT(DISTINCT IFF(case_id LIKE '%-%', case_id, NULL)) AS container_cases,
            COUNT(DISTINCT long_portfolio_id) AS cat_batches,
            MIN(registration_date::DATE) AS first_registration,
            MODE(registration_date::DATE) AS usual_registration,
            MAX(registration_date::DATE) AS last_registration
        FROM raw.hyperion_intrum_cat.cases
        WHERE _file_path LIKE $raw_prefix
            AND LEFT(long_portfolio_id, 7) IN (SELECT deal FROM deals_asked_for)
        GROUP BY 1, 2
),

    capex AS (

        SELECT
            servicer_parent_portfolio_bk AS deal,
            MIN(legacy_capex_date) AS capex_date
        FROM prod.npl_common.dim_batch
        WHERE servicer_parent_portfolio_bk IN (SELECT deal FROM deals_asked_for)
        GROUP BY 1
)

SELECT
    d.deal,
    x.capex_date,
    p.pam_segments,
    p.pam_cases,
    p.pam_principal,
    p.pam_currency,
    c.instance,
    c.cat_cases,
    c.container_cases,
    c.cat_batches,
    c.first_registration,
    c.usual_registration,
    c.last_registration
FROM deals_asked_for AS d
LEFT JOIN pam AS p
    ON p.deal = d.deal
LEFT JOIN cat AS c
    ON c.deal = d.deal
LEFT JOIN capex AS x
    ON x.deal = d.deal
ORDER BY d.deal, c.instance;
