-- Deals we have been SHOWN, and the purchase price attached to them, per market.
-- GRAIN  one row per country x sector ('SE · Financial Services'), the same market shape
--        as work/workshop/queries/deals_we_own.sql. Measured 2026-11-09: 26 rows, 236
--        deals seen, EUR 3.30bn of price seen; 9 of those deals (EUR 490m) are from
--        sellers not yet in the list. Excluding those, it matches the Sigma workbook
--        exactly but for one Belgian Santander deal created in Atlas that day.
-- RUN    mise run sql -- work/workshop/queries/deals_seen_by_market.sql
-- SOURCE Atlas's deal pipeline (RAW.ATLAS_PUBLIC) and COMMON's FX table, plus the seller
--        list written out below. Runs as NPL_ANALYST; nothing is read from Sigma.
--
-- WHAT 'SEEN' MEANS, AND WHY IT IS NOT deals_we_own.sql. A row in Atlas's DEALS_DEAL is a
-- deal that reached our pipeline: something a seller showed us, whether or not we bid and
-- whether or not we bought. deals_we_own.sql counts books we HOLD. The two populations
-- overlap but are not nested, and their totals will never tie. Do not read one as a
-- subset of the other.
--
-- ⚠ ATLAS HAS NO PRODUCT. Nothing in RAW.ATLAS_PUBLIC says what kind of debt a deal is;
-- segment names are free text ('Default', '01', 'B2C 0-500'). So the sector comes from
-- the SELLER, through a hand-made list: each Atlas seller id tagged with a seller type and
-- a product proxy. It was typed into the Asset Index Tracking Sigma workbook ('Atlas
-- seller mapping') and copied here on 2026-11-09, 145 sellers. This file is now the copy
-- that counts. A seller added to Atlas after that date is not in the list: its deals are
-- kept, as Unclassified, and unclassified_seller_deals counts them, so a stale list shows
-- up as a number instead of a silent drop. Add the seller below to place it.
--
-- ⚠ TWO DIFFERENT THINGS ARE BOTH CALLED 'FS'. seller_type says what kind of business the
-- SELLER is ('FS originator'); the sector is derived from the PRODUCT. The two disagree on
-- the four 'BNPL / invoice' sellers: FS originators whose product lands in Retail, so they
-- count as Non-Financial Services. The Sigma workbook used the product reading too.
--
-- ⚠ SECONDARY SELLERS ARE EXCLUDED, NOT MISSING. 'Secondary' sellers (another investor
-- reselling a book, 18 in the list) and the 2 'Unknown' ones are dropped, as the Sigma
-- workbook did, so 'deals seen' means deals seen FROM ORIGINATORS.
--
-- ⚠ ONE EXCHANGE RATE. Every price converts at the $fx_month rate, so a price seen in
-- 2019 is in today's money: a current-money total, not a historic one.

SET fx_month = '2026-09-30';    -- the Sigma workbook's reporting month; move it on freely

WITH
    -- Atlas seller id -> seller type and product proxy. Copied from Sigma 2026-11-09.
    seller_map (seller_id, seller_type, product_proxy) AS (

        SELECT * FROM VALUES
            (  1, 'Secondary', 'Mixed (secondary)'),  -- Intrum
            (105, 'Non-FS originator', 'Retail credit'),  -- Otto
            (107, 'FS originator', 'Consumer loan & card'),  -- Lendable
            (108, 'FS originator', 'Mixed retail banking'),  -- ING
            (109, 'FS originator', 'Consumer loan & card'),  -- TF Bank
            (110, 'Non-FS originator', 'Utility'),  -- Luminus NV
            (111, 'Secondary', 'Mixed (secondary)'),  -- Hoist
            (112, 'FS originator', 'Mixed retail banking'),  -- Credit Agricole Centre-Est
            (113, 'Secondary', 'Mixed (secondary)'),  -- Arrow Global
            (115, 'Secondary', 'Mixed (secondary)'),  -- Lowell Group
            (116, 'FS originator', 'Consumer loan & card'),  -- Findomestic
            (118, 'FS originator', 'Consumer loan'),  -- Northmill
            (119, 'FS originator', 'Consumer loan & card'),  -- NOBA
            (120, 'FS originator', 'Consumer loan'),  -- Abound
            (122, 'FS originator', 'Mixed retail banking'),  -- OP
            (123, 'FS originator', 'Consumer loan & card'),  -- MedMera Bank
            (124, 'Secondary', 'Mixed (secondary)'),  -- Blackstone
            (125, 'FS originator', 'Mixed retail banking'),  -- BBVA
            (126, 'FS originator', 'Consumer loan & card'),  -- Bank Norwegian
            (127, 'FS originator', 'Mixed retail banking'),  -- BPER Banca
            (128, 'FS originator', 'Mixed retail banking'),  -- Iccrea
            (131, 'FS originator', 'Mixed retail banking'),  -- Deutsche Bank
            (132, 'FS originator', 'Consumer loan & card'),  -- Santander Consumer Finance
            (133, 'FS originator', 'SME loan'),  -- Funding Circle
            (138, 'FS originator', 'Consumer loan'),  -- Shawbrook Bank
            (139, 'FS originator', 'Consumer loan & card'),  -- Norion Bank
            (140, 'Non-FS originator', 'Utility'),  -- Electrabel
            (146, 'FS originator', 'Consumer loan & card'),  -- BNP Paribas Personal Finance
            (147, 'FS originator', 'Consumer loan & card'),  -- Virgin Money
            (148, 'FS originator', 'Consumer loan'),  -- Moank
            (149, 'FS originator', 'Credit card'),  -- Entercard
            (150, 'FS originator', 'Consumer loan'),  -- Qander
            (152, 'FS originator', 'Mixed retail banking'),  -- Banca Popolare di Sondrio
            (153, 'FS originator', 'Mixed retail banking'),  -- ING Bank
            (154, 'FS originator', 'Mixed retail banking'),  -- Alior Bank S.A
            (155, 'FS originator', 'Mixed retail banking'),  -- BNP Paribas Bank Polska S.A.
            (156, 'FS originator', 'Mixed retail banking'),  -- Banco BPM
            (157, 'FS originator', 'Consumer loan'),  -- Abound (Fintern Ltd)
            (159, 'FS originator', 'Consumer loan & card'),  -- ConsorsFinanz
            (160, 'FS originator', 'Mixed retail banking'),  -- CaixaBank
            (161, 'FS originator', 'Consumer loan'),  -- Multitude
            (162, 'Secondary', 'Mixed (secondary)'),  -- FMP GmbH
            (163, 'FS originator', 'Consumer loan'),  -- FranFinance
            (164, 'FS originator', 'Mixed retail banking'),  -- Oma Säästöpankki Oyj
            (165, 'FS originator', 'Consumer loan & card'),  -- Morrow Bank
            (166, 'FS originator', 'Consumer loan & card'),  -- Santander Consumer Bank AG
            (168, 'FS originator', 'Mixed retail banking'),  -- Santander Bank Polska S.A.
            (169, 'FS originator', 'Consumer loan'),  -- Lea Bank
            (170, 'Secondary', 'Mixed (secondary)'),  -- Blue Owl Capital
            (173, 'FS originator', 'Consumer loan & card'),  -- Santander Consumer Bank S.A.
            (174, 'FS originator', 'Mixed retail banking'),  -- ING Bank Śląski S.A.
            (175, 'Non-FS originator', 'Retail credit'),  -- Thorn Svenska AB
            (176, 'FS originator', 'Consumer loan & card'),  -- Norion
            (180, 'FS originator', 'Mixed retail banking'),  -- PKO BP S.A.
            (181, 'FS originator', 'Consumer loan & card'),  -- Ikano Bank
            (182, 'FS originator', 'Consumer loan'),  -- Marginalen Bank
            (183, 'FS originator', 'Consumer loan & card'),  -- Norion Bank AB
            (184, 'FS originator', 'Consumer loan'),  -- 0to9
            (186, 'FS originator', 'Mixed retail banking'),  -- Santander
            (187, 'FS originator', 'BNPL / invoice'),  -- Klarna Ab
            (188, 'FS originator', 'Mixed retail banking'),  -- S-Pankki Oyj
            (189, 'FS originator', 'Consumer loan'),  -- BIGBANK AS
            (190, 'FS originator', 'Consumer loan & card'),  -- Santander Consumer Bank
            (191, 'FS originator', 'Consumer loan & card'),  -- Santander Consumer Bank S.p.A.
            (192, 'Unknown', 'Unknown'),  -- TBC
            (193, 'FS originator', 'Mixed retail banking'),  -- Velo Bank S.A.
            (194, 'Secondary', 'Mixed (secondary)'),  -- RK Recovery S.A.
            (195, 'FS originator', 'Mixed retail banking'),  -- Societe Generale
            (196, 'FS originator', 'Mixed retail banking'),  -- BankInter
            (197, 'Secondary', 'Mixed (secondary)'),  -- Carval
            (198, 'FS originator', 'Mixed retail banking'),  -- ERSTE BANK S.A.
            (199, 'FS originator', 'Mixed retail banking'),  -- Banca Popolare di Milano
            (200, 'FS originator', 'Mixed retail banking'),  -- Banca Nazionale del Lavoro S.p.A.
            (201, 'FS originator', 'Mixed retail banking'),  -- Unicaja
            (203, 'FS originator', 'Mixed retail banking'),  -- Caisse D'Epargne
            (204, 'FS originator', 'Consumer loan & card'),  -- DNB Finans As
            (205, 'FS originator', 'Mixed retail banking'),  -- mBank S.A.
            (206, 'FS originator', 'Consumer loan'),  -- Fairlo
            (207, 'Secondary', 'Mixed (secondary)'),  -- Iqera France
            (209, 'Secondary', 'Mixed (secondary)'),  -- REV - Gestione Crediti S.p.A.
            (211, 'FS originator', 'BNPL / invoice'),  -- CembraPay AG
            (212, 'FS originator', 'Mixed retail banking'),  -- Raiffeisen Digital Bank
            (213, 'FS originator', 'Auto / lease'),  -- 321 crédito
            (214, 'FS originator', 'Consumer loan'),  -- Funeral Safe
            (215, 'Secondary', 'Mixed (secondary)'),  -- Spanda
            (217, 'Secondary', 'Mixed (secondary)'),  -- Balbec
            (218, 'FS originator', 'Consumer loan & card'),  -- Targobank
            (220, 'Non-FS originator', 'Telecom'),  -- Sergel Finans Oy
            (223, 'FS originator', 'Mixed retail banking'),  -- Banca Monte dei Paschi di Siena
            (224, 'FS originator', 'Mixed retail banking'),  -- Banca Agricola Popolare di Sicilia
            (225, 'FS originator', 'SME loan'),  -- MedioCredito Centrale
            (228, 'FS originator', 'Mixed retail banking'),  -- Ibercaja
            (229, 'FS originator', 'Consumer loan & card'),  -- Tesco Bank
            (230, 'FS originator', 'Mixed retail banking'),  -- DKB Bank
            (231, 'FS originator', 'Auto / lease'),  -- Hiltermann
            (232, 'FS originator', 'Mixed retail banking'),  -- Credia Bank
            (233, 'FS originator', 'Consumer loan & card'),  -- Resurs Bank AB
            (234, 'FS originator', 'Consumer loan & card'),  -- Resurs Bank
            (235, 'FS originator', 'Mixed retail banking'),  -- Credit Mutuel
            (236, 'FS originator', 'Mixed retail banking'),  -- Gruppo Banca Popolare dell’Emilia Romagna
            (237, 'FS originator', 'Mixed retail banking'),  -- Deutsche Kreditbank AG
            (238, 'FS originator', 'Consumer loan & card'),  -- Cofidis
            (240, 'FS originator', 'Consumer loan'),  -- Provident
            (241, 'FS originator', 'Mixed retail banking'),  -- Banco Montepio
            (246, 'FS originator', 'Mixed retail banking'),  -- Sabadell
            (249, 'Secondary', 'Mixed (secondary)'),  -- Zolva
            (250, 'FS originator', 'Mixed retail banking'),  -- Unicredit
            (251, 'FS originator', 'Consumer loan'),  -- Delta
            (252, 'FS originator', 'Mixed retail banking'),  -- BPMS
            (253, 'Secondary', 'Mixed (secondary)'),  -- Hoist Finance
            (254, 'Non-FS originator', 'Utility'),  -- Luminus
            (255, 'FS originator', 'BNPL / invoice'),  -- Cembra Pay
            (256, 'FS originator', 'Consumer loan & card'),  -- Cembra Money Bank
            (257, 'FS originator', 'Consumer loan'),  -- Multitude Bank
            (258, 'FS originator', 'Mixed retail banking'),  -- BAWAG
            (259, 'FS originator', 'Consumer loan'),  -- Bonum Pankki
            (260, 'Non-FS originator', 'Telecom'),  -- DNA
            (261, 'Non-FS originator', 'Telecom'),  -- Moi Mobiili
            (262, 'Non-FS originator', 'Telecom'),  -- Elisa
            (263, 'FS originator', 'Credit card'),  -- St1 Finance
            (264, 'Non-FS originator', 'Retail credit'),  -- St1 Suomi
            (265, 'FS originator', 'Mixed retail banking'),  -- Intesa Sanpaolo
            (266, 'FS originator', 'Mixed retail banking'),  -- Crédit Agricole Italia
            (267, 'FS originator', 'Consumer loan'),  -- Qander Consumer Finance
            (268, 'FS originator', 'Credit card'),  -- Entercard Group
            (269, 'Non-FS originator', 'Telecom'),  -- Salt Mobile
            (270, 'FS originator', 'Consumer loan'),  -- Plata Finance
            (271, 'FS originator', 'Mixed retail banking'),  -- ING-DiBa
            (272, 'FS originator', 'Consumer loan'),  -- Auxmoney GmbH
            (276, 'FS originator', 'Consumer loan & card'),  -- ICA Banken
            (277, 'FS originator', 'Mixed retail banking'),  -- Banco BPI
            (278, 'FS originator', 'Consumer loan & card'),  -- ICA Banken AB
            (279, 'FS originator', 'Mixed retail banking'),  -- OP Vähittäisasiakkaat Oyj
            (280, 'FS originator', 'Mixed retail banking'),  -- Novo Banco S.A
            (281, 'Secondary', 'Mixed (secondary)'),  -- M&G FA Limited
            (282, 'FS originator', 'Mixed retail banking'),  -- Millenium BCP
            (286, 'FS originator', 'BNPL / invoice'),  -- Qliro
            (287, 'Unknown', 'Unknown'),  -- 1640
            (288, 'FS originator', 'Mortgage'),  -- Enity Bank Group
            (292, 'Secondary', 'Mixed (secondary)'),  -- Parvalorem
            (297, 'FS originator', 'Mixed retail banking'),  -- Caja Rural De Jaen
            (298, 'FS originator', 'Consumer loan & card'),  -- Beobank
            (300, 'FS originator', 'Mixed retail banking'),  -- Erste Bank
            (301, 'Secondary', 'Mixed (secondary)'),  -- Blue Factor
            (308, 'FS originator', 'Mixed retail banking')   -- mBank
),

    -- One rate per currency at month end. EUR carries its own row at 1.0 here, checked
    -- 2026-11-09, so euro deals convert rather than falling out of the sum.
    fx_to_eur AS (

        SELECT
            quote_currency AS currency_name,
            MAX(ultimo_value) AS rate_to_eur
        FROM prod.common.fct_exchange_rate_monthly
        WHERE base_currency = 'EUR'
            AND date_day = $fx_month::date
        GROUP BY 1
),

    deal_seen AS (

        SELECT
            -- Atlas says UK, DIM_BATCH says GB: one code, so a filter finds both.
            IFF(co.country_code = 'UK', 'GB', co.country_code) AS country,
            m.seller_id IS NULL AS seller_unclassified,
            -- The seller's product, collapsed to the buckets the sector is built from.
            CASE m.product_proxy
                WHEN 'Credit card' THEN 'Cards'
                WHEN 'Consumer loan' THEN 'Loans'
                WHEN 'Auto / lease' THEN 'Loans'
                WHEN 'SME loan' THEN 'Loans'
                WHEN 'Mortgage' THEN 'Loans'
                WHEN 'Mixed retail banking' THEN 'Mixed consumer credit'
                WHEN 'Consumer loan & card' THEN 'Mixed consumer credit'
                WHEN 'Telecom' THEN 'Telecom'
                WHEN 'Utility' THEN 'Utility'
                WHEN 'Retail credit' THEN 'Retail'
                WHEN 'BNPL / invoice' THEN 'Retail'
                ELSE 'Other'
            END AS product_bucket,
            -- A non-binding offer: the deal went past being looked at.
            IFF(d.nbo_date IS NOT NULL, 1, 0) AS offered_on,
            d.estimated_brocc_gross_purchase_price AS price_local,
            fx.rate_to_eur
        FROM raw.atlas_public.deals_deal AS d
        LEFT JOIN seller_map AS m
            ON m.seller_id = d.seller_id
        LEFT JOIN raw.atlas_public.companies_country AS co
            ON co.id = d.country_id
        -- Atlas keys currency by id; the FX table keys it by the three-letter name.
        LEFT JOIN raw.atlas_public.companies_currency AS cu
            ON cu.id = d.currency_id
        LEFT JOIN fx_to_eur AS fx
            ON fx.currency_name = cu.name
        WHERE d.deleted_at IS NULL
            -- An unlisted seller stays in; only the two excluded types drop out.
            AND COALESCE(m.seller_type, '') NOT IN ('Secondary', 'Unknown')
)

SELECT
    country,
    CASE
        WHEN product_bucket IN ('Cards', 'Loans', 'Mixed consumer credit')
            THEN 'Financial Services'
        WHEN product_bucket IN ('Telecom', 'Utility', 'Retail')
            THEN 'Non-Financial Services'
        ELSE 'Unclassified'
    END AS sector,
    country || ' · ' || sector AS market,
    COUNT(*) AS deals_seen,
    SUM(offered_on) AS deals_offered_on,
    -- A deal whose currency has no rate contributes NULL, not zero, so a missing rate
    -- shows up as a thin total rather than disappearing quietly.
    SUM(price_local * rate_to_eur) AS purchase_price_seen_eur,
    COUNT_IF(seller_unclassified) AS unclassified_seller_deals
FROM deal_seen
GROUP BY 1, 2
ORDER BY purchase_price_seen_eur DESC NULLS LAST;
