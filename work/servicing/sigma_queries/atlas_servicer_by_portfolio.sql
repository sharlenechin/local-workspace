-- The servicer of every portfolio as Atlas (the portfolio management system) records it, for comparison with the
-- dashboard's rule (servicer from deal source + country). Grain: one row per Atlas batch-segment, which is the
-- dashboard's portfolio: portfolio_bk = deal code + '-' + batch-segment display id, as int_npl_portfolio_atlas builds it.
-- In the Atlas test copy on 2026-10-13: 438 batch-segments, all with a servicer id; 81 deals, 2 with a second servicer
-- (Heimdall Spain LOK-ES24013 and Roma LOK-ES25004, both primary Intrum, second servicer id 2).
--
-- ⚠ Reads Atlas's TEST environment, not production: the views in the brocc-sandbox account (DEV.CI_NDP798, a CI
-- build of brocc-data's staging models) select from raw.atlas_staging_public, while PROD is built from atlas_public.
-- Indicative only: in the test copy only Intrum (id 1) has a company name; ids 2, 4, 5, 34 have none. It is the only
-- Atlas the analyst roles can read, because PROD exposes no servicer (int_npl_portfolio_atlas does not select
-- servicer_id) and NPL_ANALYST cannot read RAW.ATLAS_PUBLIC. Run with the `dev` connection. Read-only.

SELECT
    d.deal_bk || '-' || bs.display_id   AS portfolio_bk,
    d.deal_bk,
    d.deal_name,
    bs_srv.name                         AS servicer,           -- per portfolio
    deal_srv.name                       AS deal_servicer,      -- per deal, a cross-check
    deal_srv2.name                      AS deal_second_servicer
FROM DEV.CI_NDP798.STG_ATLAS__DEALS_BATCH_SEGMENT AS bs
INNER JOIN DEV.CI_NDP798.STG_ATLAS__DEALS_SEGMENT AS s
    ON s.segment_id = bs.segment_id
INNER JOIN DEV.CI_NDP798.STG_ATLAS__DEALS_DEAL AS d
    ON d.deal_id = s.deal_id
LEFT JOIN DEV.CI_NDP798.STG_ATLAS__COMPANIES_COMPANY AS bs_srv
    ON bs_srv.id = bs.servicer_id
LEFT JOIN DEV.CI_NDP798.STG_ATLAS__COMPANIES_COMPANY AS deal_srv
    ON deal_srv.id = d.servicer_id
LEFT JOIN DEV.CI_NDP798.STG_ATLAS__COMPANIES_COMPANY AS deal_srv2
    ON deal_srv2.id = d.second_servicer_id
-- Soft-deleted Atlas rows are kept in staging with a flag; the portfolio model ignores none explicitly, so show them.
ORDER BY 1
