-- How far back the 'deals seen' population goes, so the deck can name a real
-- start date instead of 'since 2025'.
--
--   RUN    mise run sql -- work/workshop/queries/deals_seen_date_range.sql
--   GRAIN  one row per year a deal was created in Atlas, plus a TOTAL row.
--   SOURCE raw.atlas_public.deals_deal — the SAME population as
--          work/workshop/queries/deals_seen_by_market.sql: deleted rows out,
--          'Secondary' and 'Unknown' sellers out, no date filter of any kind.
--          The seller list below is copied from that file unchanged.
--
-- WHICH DATE. created_at is when the deal was entered in Atlas, which is the
-- closest thing to 'when we saw it'. nbo_date is when we made a non-binding
-- offer, so it exists only for deals that went past being looked at and is
-- shown here beside it rather than used as the headline.
--
-- ⚠ Atlas's own history starts when the system was adopted; a deal seen before
--   that is not in here at all, however early created_at looks.
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

    deal_seen AS (
        SELECT
            d.id,
            d.created_at::date AS created_date,
            d.nbo_date
        FROM raw.atlas_public.deals_deal AS d
        LEFT JOIN seller_map AS m
            ON m.seller_id = d.seller_id
        WHERE d.deleted_at IS NULL
            AND COALESCE(m.seller_type, '') NOT IN ('Secondary', 'Unknown')
    )

SELECT
    YEAR(created_date)::varchar AS created_year,
    COUNT(*)                    AS deals,
    MIN(created_date)           AS first_created,
    MAX(created_date)           AS last_created,
    COUNT(nbo_date)             AS deals_with_an_offer,
    MIN(nbo_date)               AS first_offer
FROM deal_seen
GROUP BY 1
UNION ALL
SELECT
    'TOTAL',
    COUNT(*),
    MIN(created_date),
    MAX(created_date),
    COUNT(nbo_date),
    MIN(nbo_date)
FROM deal_seen
ORDER BY created_year;
