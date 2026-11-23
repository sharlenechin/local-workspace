-- SE17039 (SevenDay, HEI) accounts: one row per cleaned_cases per month-end.
--
-- COLUMN NAMES say where each value comes from: asset_index_ is the seller's tape as loaded into
-- the asset index, warehouse_ is Brocc's data warehouse, and warehouse_vs_pam_ compares the
-- warehouse with Intrum's own monthly report. Identifiers and the month have no prefix.
--
-- WHICH cleaned_casesS. Every cleaned_cases we own in this deal. A cleaned_cases counts as ours when the warehouse's
-- month-end balance table puts one of its Intrum cases in an SE17039 batch. Whether a cleaned_cases has
-- ever paid does not matter.
--
-- ONE cleaned_cases CAN HAVE TWO INTRUM CASES. Intrum moved 607 of these cleaned_casess from its system 1062 to its
-- system 2080: 268 in December 2022, 300 in May 2024 and 39 at other dates between February 2023
-- and March 2026. Each move opened a new case on 2080 and, the same day or the day after, closed
-- the old case on 1062 with closing code 9. The warehouse keeps both cases, and keeps reporting a
-- balance on the closed old case, so counting cases would count these cleaned_casess twice. Here each is
-- one cleaned_cases:
--   · model_id is the new case and previous_model_id the old one;
--   · each month is reported by the old case up to the month before the move, and by the new case
--     from the month of the move;
--   · collections are added up over both cases.
-- Intrum's data has no field linking the two cases, so the 607 pairs are listed below. A pair was
-- kept when the old case closed with code 9 within a day of the new case opening and either their
-- principal was equal on those dates (511 pairs) or their payments matched month by month to the
-- öre (338 pairs, 242 of them also equal on principal). Four pairs matched on payments only and
-- did not close that way, and are left out. Measured 20 November 2026; the working is in
-- bridge_check/.
--
-- WHICH MONTHS. Every month-end from the seller's tape cut-off (2 November 2017, so the first row
-- is 30 November 2017) to the latest month-end in the warehouse.
--   · Tape fields (balance at cut-off, product, birth year, flags) repeat on every row. They are
--     empty for cleaned_casess the seller's tape does not cover.
--   · Registration date, default date and balance at registration repeat on every row.
--     warehouse_balance_at_registration is the balance at the end of the registration month. It is filled
--     for 453 of the 455 cleaned_casess registered on system 2080 and never moved, and empty for every cleaned_cases
--     first registered on system 1062, because the warehouse has no balance for those cases from
--     that far back.
--   · Balance, status and closing are as at that month-end, from the warehouse. They are empty
--     before registration, and for cleaned_casess on system 1062 also until the warehouse's record of the
--     case starts, which is between March 2021 and October 2024.
--
-- COLLECTIONS. warehouse_collected_in_month comes from the warehouse's collections table. For this deal that
-- table holds nothing for system 1062 and about three quarters of what Intrum reported for system
-- 2080. Every row carries the deal-wide check against Intrum's own monthly report (PAM), built as
-- in payments.sql. Do not use warehouse_collected_in_month while warehouse_reconciles_with_pam is FALSE.
-- Payments after the last month-end row are not in this file (SEK 57,554.56 paid in November
-- 2026 at the time of measuring), so its total is that much below payments.sql.
--
-- Measured 20 November 2026: 2,095 cleaned_casess x 108 month-ends = 226,260 rows. 2,085 cleaned_casess are on
-- the seller's tape. Collections SEK 68,580,992.07, which is 50.90859% below PAM over December
-- 2018 to October 2026, so warehouse_reconciles_with_pam is FALSE on every row. Runs in about 5 minutes.

SET portfolio_id = 'SE17039';
SET max_total_deviation_pct = 10;
SET min_month_coverage_pct = 80;

WITH
-- Old case on 1062, new case on 2080, one pair per moved cleaned_cases.
moved_cleaned_cases AS (
    SELECT
        column1 AS old_case,
        column2 AS new_case
    FROM VALUES
        ('1062-2068021', '2080-2161914'), ('1062-2101321', '2080-2161943'), ('1062-2113684', '2080-2161979'), ('1062-2113955', '2080-2161980'),
        ('1062-2118866', '2080-1944253'), ('1062-2120226', '2080-2161987'), ('1062-4919755', '2080-1948198'), ('1062-4919812', '2080-1948199'),
        ('1062-4970085', '2080-1948271'), ('1062-4994114', '2080-2162423'), ('1062-4995603', '2080-1948300'), ('1062-5003461', '2080-1948314'),
        ('1062-5003482', '2080-1948315'), ('1062-5003483', '2080-2162425'), ('1062-5003521', '2080-2162426'), ('1062-5007754', '2080-1948321'),
        ('1062-5012174', '2080-1948326'), ('1062-5015365', '2080-2162429'), ('1062-5026860', '2080-1948351'), ('1062-5059703', '2080-1948380'),
        ('1062-5065467', '2080-1948388'), ('1062-5074328', '2080-1948395'), ('1062-5095157', '2080-2162447'), ('1062-5125515', '2080-1948453'),
        ('1062-5126593', '2080-2162450'), ('1062-5126642', '2080-1996476'), ('1062-5128763', '2080-1948457'), ('1062-5132617', '2080-2162452'),
        ('1062-5138172', '2080-1948466'), ('1062-5151380', '2080-2162455'), ('1062-5155765', '2080-1948484'), ('1062-5162944', '2080-1948499'),
        ('1062-5187891', '2080-2162463'), ('1062-5203710', '2080-1948545'), ('1062-5203989', '2080-2162467'), ('1062-5210354', '2080-1948552'),
        ('1062-5212301', '2080-2162469'), ('1062-5213414', '2080-2162470'), ('1062-5213529', '2080-1948555'), ('1062-5222643', '2080-1948562'),
        ('1062-5230828', '2080-2125675'), ('1062-5232850', '2080-1948581'), ('1062-5234943', '2080-1948584'), ('1062-5252383', '2080-2162481'),
        ('1062-5252532', '2080-1948609'), ('1062-5252731', '2080-2162482'), ('1062-5257269', '2080-2162483'), ('1062-5257406', '2080-2162484'),
        ('1062-5257607', '2080-2162485'), ('1062-5257652', '2080-2162486'), ('1062-5258218', '2080-2162487'), ('1062-5260598', '2080-1948625'),
        ('1062-5261505', '2080-2162488'), ('1062-5264146', '2080-1948629'), ('1062-5268214', '2080-1948636'), ('1062-5269795', '2080-2162490'),
        ('1062-5277153', '2080-2162492'), ('1062-5280951', '2080-1948665'), ('1062-5283206', '2080-2162494'), ('1062-5283322', '2080-2162496'),
        ('1062-5283769', '2080-2162497'), ('1062-5284506', '2080-2162498'), ('1062-5287017', '2080-1948679'), ('1062-5288585', '2080-2162500'),
        ('1062-5293521', '2080-2125684'), ('1062-5301875', '2080-2162502'), ('1062-5305801', '2080-2162503'), ('1062-5320414', '2080-2162505'),
        ('1062-5320599', '2080-1948742'), ('1062-5320709', '2080-1948743'), ('1062-5328246', '2080-2162507'), ('1062-5338749', '2080-1948763'),
        ('1062-5338935', '2080-1948764'), ('1062-5348372', '2080-2162509'), ('1062-5351451', '2080-2162511'), ('1062-5356004', '2080-2162512'),
        ('1062-5359926', '2080-2162515'), ('1062-5361286', '2080-1948809'), ('1062-5361301', '2080-2248767'), ('1062-5361321', '2080-1948810'),
        ('1062-5369933', '2080-2162519'), ('1062-5373829', '2080-1948834'), ('1062-5384164', '2080-1948846'), ('1062-5388576', '2080-1948853'),
        ('1062-5399696', '2080-1948871'), ('1062-5414050', '2080-2162532'), ('1062-5419487', '2080-1948907'), ('1062-5419770', '2080-2125696'),
        ('1062-5424504', '2080-2162535'), ('1062-5424525', '2080-1948946'), ('1062-5424562', '2080-1948947'), ('1062-5426894', '2080-1948956'),
        ('1062-5426957', '2080-1948958'), ('1062-5428784', '2080-1948959'), ('1062-5433040', '2080-1948974'), ('1062-5433909', '2080-2162536'),
        ('1062-5434861', '2080-2162537'), ('1062-5435177', '2080-1948981'), ('1062-5437858', '2080-2162539'), ('1062-5441741', '2080-1949000'),
        ('1062-5441982', '2080-1996548'), ('1062-5442051', '2080-1949001'), ('1062-5450624', '2080-1996550'), ('1062-5458452', '2080-2162545'),
        ('1062-5460548', '2080-2162546'), ('1062-5460717', '2080-2162547'), ('1062-5471372', '2080-2245373'), ('1062-5471715', '2080-2162550'),
        ('1062-5475230', '2080-1949077'), ('1062-5476191', '2080-2162551'), ('1062-5499381', '2080-1949118'), ('1062-5500525', '2080-1949121'),
        ('1062-5508416', '2080-2162568'), ('1062-5519760', '2080-1949168'), ('1062-5525602', '2080-2162571'), ('1062-5530235', '2080-1949196'),
        ('1062-5534490', '2080-1949206'), ('1062-5534838', '2080-1949207'), ('1062-5535014', '2080-2162572'), ('1062-5538007', '2080-1949216'),
        ('1062-5538415', '2080-1983107'), ('1062-5547717', '2080-1949235'), ('1062-5551055', '2080-1949242'), ('1062-5551356', '2080-2162574'),
        ('1062-5552400', '2080-2162575'), ('1062-5553881', '2080-1996576'), ('1062-5553882', '2080-1949248'), ('1062-5553971', '2080-1949249'),
        ('1062-5554269', '2080-1949250'), ('1062-5561590', '2080-2162577'), ('1062-5563038', '2080-1949266'), ('1062-5567088', '2080-2162580'),
        ('1062-5568810', '2080-1949278'), ('1062-5570095', '2080-2162584'), ('1062-5570162', '2080-2162585'), ('1062-5576057', '2080-2162590'),
        ('1062-5576095', '2080-1949300'), ('1062-5583184', '2080-2162591'), ('1062-5584735', '2080-1949320'), ('1062-5585718', '2080-2162592'),
        ('1062-5587483', '2080-1949322'), ('1062-5587856', '2080-1949323'), ('1062-5590419', '2080-2162597'), ('1062-5590474', '2080-2162598'),
        ('1062-5598952', '2080-2162603'), ('1062-5601003', '2080-2162604'), ('1062-5608767', '2080-2162607'), ('1062-5608958', '2080-2162609'),
        ('1062-5610633', '2080-1949361'), ('1062-5612682', '2080-1949363'), ('1062-5618974', '2080-1949376'), ('1062-5622284', '2080-2162614'),
        ('1062-5623507', '2080-1949391'), ('1062-5624131', '2080-1949397'), ('1062-5627583', '2080-1949400'), ('1062-5633013', '2080-1949434'),
        ('1062-5635501', '2080-1949437'), ('1062-5641647', '2080-1949446'), ('1062-5644382', '2080-2162619'), ('1062-5649775', '2080-1949466'),
        ('1062-5653346', '2080-2162622'), ('1062-5654825', '2080-1949470'), ('1062-5656745', '2080-1949474'), ('1062-5661552', '2080-1949483'),
        ('1062-5670945', '2080-1949496'), ('1062-5671351', '2080-1996602'), ('1062-5671775', '2080-2162630'), ('1062-5671784', '2080-2162631'),
        ('1062-5673221', '2080-1949500'), ('1062-5673622', '2080-2162634'), ('1062-5674033', '2080-1949503'), ('1062-5675703', '2080-2162636'),
        ('1062-5675729', '2080-1949507'), ('1062-5681542', '2080-1996604'), ('1062-5682022', '2080-2162639'), ('1062-5682052', '2080-2162640'),
        ('1062-5685051', '2080-1949524'), ('1062-5687241', '2080-1949530'), ('1062-5688612', '2080-1949535'), ('1062-5691000', '2080-1949544'),
        ('1062-5692422', '2080-1983110'), ('1062-5692794', '2080-1949550'), ('1062-5693409', '2080-2125760'), ('1062-5695010', '2080-2162641'),
        ('1062-5698246', '2080-1949558'), ('1062-5701020', '2080-2162643'), ('1062-5701101', '2080-1949564'), ('1062-5703645', '2080-2162645'),
        ('1062-5707455', '2080-2162648'), ('1062-5713841', '2080-2162649'), ('1062-5716315', '2080-2162650'), ('1062-5719537', '2080-2125765'),
        ('1062-5723511', '2080-1949614'), ('1062-5733107', '2080-2162652'), ('1062-5736064', '2080-1949639'), ('1062-5738239', '2080-2162653'),
        ('1062-5738396', '2080-2162654'), ('1062-5738747', '2080-2125770'), ('1062-5740623', '2080-2162655'), ('1062-5744061', '2080-2162656'),
        ('1062-5745112', '2080-2162657'), ('1062-5745192', '2080-1949653'), ('1062-5746253', '2080-2162658'), ('1062-5746299', '2080-2162659'),
        ('1062-5746354', '2080-1949656'), ('1062-5747479', '2080-1996618'), ('1062-5749196', '2080-1949662'), ('1062-5749197', '2080-1949663'),
        ('1062-5750998', '2080-2162661'), ('1062-5752308', '2080-2162662'), ('1062-5753064', '2080-2162664'), ('1062-5764269', '2080-2162669'),
        ('1062-5765802', '2080-1949691'), ('1062-5776035', '2080-1949726'), ('1062-5776065', '2080-2162678'), ('1062-5777701', '2080-2125773'),
        ('1062-5783428', '2080-2162681'), ('1062-5790730', '2080-2162683'), ('1062-5792445', '2080-2162684'), ('1062-5792936', '2080-2162685'),
        ('1062-5792944', '2080-2125775'), ('1062-5793017', '2080-1949759'), ('1062-5794105', '2080-2162686'), ('1062-5797537', '2080-1983114'),
        ('1062-5800223', '2080-1949784'), ('1062-5802584', '2080-1949788'), ('1062-5804108', '2080-1949795'), ('1062-5805989', '2080-1949800'),
        ('1062-5806819', '2080-2162688'), ('1062-5806872', '2080-2162689'), ('1062-5811871', '2080-1949821'), ('1062-5815945', '2080-1949834'),
        ('1062-5815961', '2080-2162691'), ('1062-5817214', '2080-2162692'), ('1062-5817263', '2080-1949838'), ('1062-5817314', '2080-1949839'),
        ('1062-5819975', '2080-2162695'), ('1062-5820259', '2080-1949846'), ('1062-5821915', '2080-1949854'), ('1062-5822025', '2080-2162696'),
        ('1062-5825725', '2080-2125784'), ('1062-5827273', '2080-1949865'), ('1062-5827919', '2080-1949867'), ('1062-5829740', '2080-1949869'),
        ('1062-5835737', '2080-2162700'), ('1062-5836529', '2080-2125787'), ('1062-5837205', '2080-2162701'), ('1062-5840938', '2080-1949893'),
        ('1062-5841668', '2080-2162702'), ('1062-5844187', '2080-2162705'), ('1062-5844205', '2080-1949898'), ('1062-5849492', '2080-1949905'),
        ('1062-5851046', '2080-1949922'), ('1062-5851396', '2080-1949924'), ('1062-5851754', '2080-2212983'), ('1062-5851773', '2080-2162713'),
        ('1062-5855672', '2080-2162714'), ('1062-5855688', '2080-2162715'), ('1062-5861863', '2080-2125794'), ('1062-5863383', '2080-2162720'),
        ('1062-5864241', '2080-2162721'), ('1062-5870117', '2080-1950039'), ('1062-5870159', '2080-1950040'), ('1062-5876727', '2080-2162724'),
        ('1062-5878022', '2080-2162725'), ('1062-5879712', '2080-1950169'), ('1062-5879719', '2080-2162726'), ('1062-5882254', '2080-2162729'),
        ('1062-5884424', '2080-2162730'), ('1062-5890261', '2080-1950257'), ('1062-5892406', '2080-1996662'), ('1062-5893109', '2080-1950265'),
        ('1062-5897050', '2080-1950293'), ('1062-5897054', '2080-1950294'), ('1062-5897059', '2080-2162740'), ('1062-5900585', '2080-1950304'),
        ('1062-5905077', '2080-2162743'), ('1062-5906070', '2080-2245351'), ('1062-5906140', '2080-2162745'), ('1062-5906469', '2080-2162746'),
        ('1062-5907056', '2080-1950316'), ('1062-5907057', '2080-1950317'), ('1062-5907452', '2080-2162751'), ('1062-5911642', '2080-1950330'),
        ('1062-5911726', '2080-2162756'), ('1062-5912689', '2080-2162757'), ('1062-5913012', '2080-2162758'), ('1062-5913205', '2080-2162760'),
        ('1062-5915269', '2080-1950355'), ('1062-5919005', '2080-1950368'), ('1062-5923215', '2080-1950379'), ('1062-5923229', '2080-1950380'),
        ('1062-5925387', '2080-2162770'), ('1062-5927238', '2080-1950386'), ('1062-5927239', '2080-2162772'), ('1062-5927290', '2080-1950387'),
        ('1062-5927689', '2080-2162773'), ('1062-5932964', '2080-2162774'), ('1062-5933872', '2080-2162775'), ('1062-5936661', '2080-1950413'),
        ('1062-5937974', '2080-2162776'), ('1062-5937975', '2080-1950418'), ('1062-5938010', '2080-1950419'), ('1062-5938331', '2080-2162777'),
        ('1062-5938592', '2080-1950422'), ('1062-5941230', '2080-2162779'), ('1062-5945474', '2080-2162781'), ('1062-5945681', '2080-2162782'),
        ('1062-5945863', '2080-1950437'), ('1062-5946862', '2080-2162783'), ('1062-5949593', '2080-2162786'), ('1062-5951998', '2080-2162788'),
        ('1062-5956455', '2080-2162789'), ('1062-5957534', '2080-1950481'), ('1062-5960536', '2080-2162793'), ('1062-5961083', '2080-1950496'),
        ('1062-5961102', '2080-1950497'), ('1062-5961253', '2080-1950498'), ('1062-5967435', '2080-2162795'), ('1062-5967458', '2080-1950524'),
        ('1062-5967461', '2080-2162796'), ('1062-5967467', '2080-1950525'), ('1062-5968649', '2080-1950529'), ('1062-5970467', '2080-2162797'),
        ('1062-5971926', '2080-1950533'), ('1062-5977711', '2080-2162799'), ('1062-5978240', '2080-1950564'), ('1062-5980341', '2080-2162802'),
        ('1062-5980345', '2080-2162803'), ('1062-5980346', '2080-1950575'), ('1062-5980348', '2080-1950576'), ('1062-5980379', '2080-2162804'),
        ('1062-5982330', '2080-2162806'), ('1062-5982335', '2080-2162807'), ('1062-5982352', '2080-1950579'), ('1062-5982545', '2080-2162808'),
        ('1062-5983571', '2080-2162809'), ('1062-5983591', '2080-2162810'), ('1062-5983616', '2080-2162811'), ('1062-5983618', '2080-1950581'),
        ('1062-5986822', '2080-1950587'), ('1062-5986835', '2080-2162814'), ('1062-5986837', '2080-2162815'), ('1062-5986841', '2080-2162816'),
        ('1062-5987137', '2080-1950591'), ('1062-5991518', '2080-2162824'), ('1062-5991549', '2080-1950613'), ('1062-5991567', '2080-2162825'),
        ('1062-5991636', '2080-2162826'), ('1062-5995168', '2080-2162830'), ('1062-5995176', '2080-1950623'), ('1062-5995181', '2080-1950624'),
        ('1062-5996714', '2080-1950631'), ('1062-5998148', '2080-2162832'), ('1062-5999154', '2080-2162833'), ('1062-6005821', '2080-1996705'),
        ('1062-6005865', '2080-2162835'), ('1062-6006452', '2080-2162839'), ('1062-6010120', '2080-2262672'), ('1062-6011349', '2080-2162843'),
        ('1062-6011353', '2080-1950681'), ('1062-6011355', '2080-1950682'), ('1062-6011359', '2080-2162844'), ('1062-6012039', '2080-1950692'),
        ('1062-6014077', '2080-2162845'), ('1062-6014152', '2080-1950697'), ('1062-6015675', '2080-2162846'), ('1062-6015691', '2080-1950700'),
        ('1062-6017270', '2080-2162848'), ('1062-6017291', '2080-1950710'), ('1062-6017399', '2080-1950711'), ('1062-6017407', '2080-2162849'),
        ('1062-6017433', '2080-1950712'), ('1062-6022135', '2080-2162857'), ('1062-6022161', '2080-2162858'), ('1062-6022162', '2080-1950729'),
        ('1062-6022184', '2080-2162859'), ('1062-6022185', '2080-1950730'), ('1062-6022893', '2080-2162860'), ('1062-6023369', '2080-1950736'),
        ('1062-6024219', '2080-1950740'), ('1062-6024619', '2080-1950744'), ('1062-6024647', '2080-1950745'), ('1062-6024719', '2080-2162861'),
        ('1062-6027189', '2080-2162864'), ('1062-6027375', '2080-1950752'), ('1062-6028992', '2080-2162866'), ('1062-6029302', '2080-1950760'),
        ('1062-6029306', '2080-1950761'), ('1062-6029315', '2080-2162868'), ('1062-6029321', '2080-2162869'), ('1062-6030967', '2080-1950776'),
        ('1062-6030985', '2080-1950777'), ('1062-6031092', '2080-2162870'), ('1062-6031168', '2080-1950779'), ('1062-6032321', '2080-2162872'),
        ('1062-6033712', '2080-2162874'), ('1062-6040857', '2080-2162879'), ('1062-6041191', '2080-2162880'), ('1062-6041198', '2080-2162881'),
        ('1062-6041201', '2080-1950815'), ('1062-6041206', '2080-2162882'), ('1062-6041217', '2080-1950816'), ('1062-6041927', '2080-2162884'),
        ('1062-6042123', '2080-1950824'), ('1062-6042335', '2080-2162888'), ('1062-6042436', '2080-1950825'), ('1062-6043874', '2080-1950843'),
        ('1062-6043891', '2080-1950844'), ('1062-6043903', '2080-1950845'), ('1062-6046874', '2080-2162892'), ('1062-6048191', '2080-1950861'),
        ('1062-6048645', '2080-2162893'), ('1062-6048646', '2080-1950866'), ('1062-6048661', '2080-1950867'), ('1062-6048684', '2080-1950869'),
        ('1062-6050368', '2080-2162895'), ('1062-6052203', '2080-1950888'), ('1062-6052748', '2080-1950893'), ('1062-6053568', '2080-1950896'),
        ('1062-6053600', '2080-1950897'), ('1062-6055770', '2080-2162899'), ('1062-6058636', '2080-1950923'), ('1062-6060639', '2080-2162900'),
        ('1062-6060653', '2080-1996736'), ('1062-6061186', '2080-1950933'), ('1062-6061331', '2080-2162901'), ('1062-6065599', '2080-2162904'),
        ('1062-6065606', '2080-1950939'), ('1062-6067376', '2080-1950949'), ('1062-6067679', '2080-2162906'), ('1062-6071733', '2080-1950967'),
        ('1062-6071735', '2080-1950968'), ('1062-6073294', '2080-1950974'), ('1062-6075265', '2080-2162911'), ('1062-6075734', '2080-2162913'),
        ('1062-6076727', '2080-2162916'), ('1062-6079857', '2080-2125890'), ('1062-6082877', '2080-2162918'), ('1062-6090504', '2080-1951060'),
        ('1062-6097342', '2080-2162931'), ('1062-6097368', '2080-1951084'), ('1062-6098325', '2080-2162932'), ('1062-6101357', '2080-2162934'),
        ('1062-6101372', '2080-1951107'), ('1062-6101805', '2080-2162935'), ('1062-6102537', '2080-1951113'), ('1062-6102577', '2080-1951114'),
        ('1062-6103203', '2080-2162938'), ('1062-6104082', '2080-1951121'), ('1062-6105676', '2080-1951125'), ('1062-6107187', '2080-2162944'),
        ('1062-6108815', '2080-2162946'), ('1062-6109649', '2080-1951137'), ('1062-6110068', '2080-2162948'), ('1062-6114508', '2080-2162949'),
        ('1062-6114513', '2080-1951152'), ('1062-6117635', '2080-2245265'), ('1062-6117660', '2080-1951176'), ('1062-6118402', '2080-2162951'),
        ('1062-6118408', '2080-1951182'), ('1062-6122792', '2080-2162957'), ('1062-6122793', '2080-2162958'), ('1062-6122843', '2080-2162960'),
        ('1062-6128725', '2080-1951243'), ('1062-6128734', '2080-2162965'), ('1062-6128753', '2080-2162966'), ('1062-6128782', '2080-2162967'),
        ('1062-6128783', '2080-1951244'), ('1062-6128805', '2080-2213077'), ('1062-6131681', '2080-2162970'), ('1062-6132221', '2080-2162971'),
        ('1062-6132227', '2080-1951261'), ('1062-6132237', '2080-1951262'), ('1062-6132250', '2080-2162972'), ('1062-6133713', '2080-2162974'),
        ('1062-6136648', '2080-1951281'), ('1062-6139849', '2080-2162978'), ('1062-6141266', '2080-1951297'), ('1062-6142789', '2080-1951306'),
        ('1062-6143135', '2080-1951307'), ('1062-6145341', '2080-2162982'), ('1062-6146063', '2080-1951325'), ('1062-6147413', '2080-1951329'),
        ('1062-6147414', '2080-2162983'), ('1062-6147418', '2080-1951330'), ('1062-6147419', '2080-2162984'), ('1062-6147599', '2080-1996806'),
        ('1062-6149041', '2080-2162985'), ('1062-6149954', '2080-2162987'), ('1062-6149963', '2080-2162989'), ('1062-6151721', '2080-1951362'),
        ('1062-6152542', '2080-1951366'), ('1062-6155840', '2080-2162992'), ('1062-6155854', '2080-2162993'), ('1062-6155884', '2080-2162994'),
        ('1062-6160497', '2080-2162998'), ('1062-6162699', '2080-1951414'), ('1062-6164693', '2080-2163002'), ('1062-6167282', '2080-2163006'),
        ('1062-6167294', '2080-1951438'), ('1062-6167774', '2080-2163007'), ('1062-6167792', '2080-2163008'), ('1062-6167808', '2080-1951440'),
        ('1062-6168455', '2080-1951448'), ('1062-6171327', '2080-2163014'), ('1062-6172002', '2080-1951473'), ('1062-6179264', '2080-1951514'),
        ('1062-6181106', '2080-2163021'), ('1062-6181107', '2080-2163022'), ('1062-6185708', '2080-1951550'), ('1062-6186035', '2080-1951552'),
        ('1062-6186042', '2080-2163029'), ('1062-6193521', '2080-2163035'), ('1062-6197426', '2080-1951619'), ('1062-6197427', '2080-1951620'),
        ('1062-6197438', '2080-1951621'), ('1062-6197450', '2080-2163048'), ('1062-6198633', '2080-2163050'), ('1062-6198956', '2080-1951630'),
        ('1062-6198976', '2080-1951631'), ('1062-6199990', '2080-1951637'), ('1062-6202641', '2080-2163055'), ('1062-6204443', '2080-2163058'),
        ('1062-6204884', '2080-1951674'), ('1062-6209599', '2080-1951819'), ('1062-6209601', '2080-2163080'), ('1062-6210609', '2080-1951829'),
        ('1062-6211588', '2080-2163082'), ('1062-6217816', '2080-2163089'), ('1062-6219901', '2080-1951899'), ('1062-6226653', '2080-2245198'),
        ('1062-6228228', '2080-2163108'), ('1062-6233502', '2080-2163124'), ('1062-6236724', '2080-2163128'), ('1062-6240522', '2080-1952102'),
        ('1062-6240543', '2080-1952103'), ('1062-6241049', '2080-2163131'), ('1062-6241951', '2080-2163138'), ('1062-6242362', '2080-2163139'),
        ('1062-6245515', '2080-1952258'), ('1062-6258346', '2080-2163159'), ('1062-6261197', '2080-2163165'), ('1062-6270478', '2080-1952492'),
        ('1062-6274370', '2080-1952692'), ('1062-6274377', '2080-2163178'), ('1062-6280495', '2080-1952765'), ('1062-6282627', '2080-2163186'),
        ('1062-6289607', '2080-2163197'), ('1062-6289608', '2080-2163198'), ('1062-6368067', '2080-1954289'), ('1062-6370896', '2080-1954595'),
        ('1062-6371985', '2080-2163295'), ('1062-6373313', '2080-2163297'), ('1062-6373325', '2080-1954778'), ('1062-6373327', '2080-2163298'),
        ('1062-6373368', '2080-1996990'), ('1062-6373398', '2080-2163299'), ('1062-6373400', '2080-2163300'), ('1062-6373435', '2080-2163301'),
        ('1062-6373436', '2080-1954781'), ('1062-6373437', '2080-2163302'), ('1062-6373445', '2080-2163303'), ('1062-6373482', '2080-1954782'),
        ('1062-6373483', '2080-2163304'), ('1062-6385821', '2080-2163330'), ('1062-6386310', '2080-2163334'), ('1062-6409664', '2080-2163372'),
        ('1062-6413000', '2080-2163374'), ('1062-6414174', '2080-1955946'), ('1062-6414175', '2080-2163380'), ('1062-6414183', '2080-2245356'),
        ('1062-6419735', '2080-2163391'), ('1062-6427784', '2080-2163403'), ('1062-6436159', '2080-2163407'), ('1062-6437047', '2080-2163409'),
        ('1062-6448004', '2080-1956708'), ('1062-6450233', '2080-1956730'), ('1062-6452383', '2080-1956744'), ('1062-6458419', '2080-2163446'),
        ('1062-6459683', '2080-2213594'), ('1062-6462443', '2080-2163450'), ('1062-6462444', '2080-2163451'), ('1062-6494383', '2080-2163507'),
        ('1062-6502973', '2080-1957824'), ('1062-6515498', '2080-2163537'), ('1062-6529331', '2080-2163559'), ('1062-6538628', '2080-2163571'),
        ('1062-6541691', '2080-2163582'), ('1062-6552895', '2080-2163611'), ('1062-6576091', '2080-1959129'), ('1062-6581712', '2080-2163649'),
        ('1062-6584585', '2080-2163658'), ('1062-6594546', '2080-1959242'), ('1062-6623265', '2080-2163685'), ('1062-6624163', '2080-2163689'),
        ('1062-6641830', '2080-1959538'), ('1062-6666604', '2080-1959804'), ('1062-6753993', '2080-1960262'), ('1062-6769247', '2080-2163901'),
        ('1062-6771035', '2080-1960547'), ('1062-6792763', '2080-1997468'), ('1062-6815701', '2080-2126197'), ('1062-6837376', '2080-2164203'),
        ('1062-6841959', '2080-2164219'), ('1062-6856535', '2080-2164570'), ('1062-6857800', '2080-1962125')
),

-- Every month-end row the warehouse holds for the deal's cases. A case's details can change over
-- time and each row points to the version current at that month-end, which gives the status then.
monthly_cases AS (
    SELECT
        c.case_bk,
        s.case_id AS case_id_hashed,
        s.case_sk,
        s.batch_sk,
        s.date_day AS month_end,
        s.outstanding_principal,
        s.outstanding_interest,
        s.outstanding_fees,
        s.outstanding_total,
        s.forbearance_flag
    FROM prod.npl_common.fct_case_snapshot_daily AS s
    INNER JOIN prod.npl_common.dim_batch AS b
        ON b.batch_sk = s.batch_sk
    INNER JOIN prod.npl_common.dim_case AS c
        ON c.case_sk = s.case_sk
    WHERE b.servicer_parent_portfolio_bk = $portfolio_id
),

-- One row per case we own, from its latest month-end.
cases_owned AS (
    SELECT
        case_bk,
        case_id_hashed,
        batch_sk
    FROM monthly_cases
    QUALIFY ROW_NUMBER() OVER (PARTITION BY case_bk ORDER BY month_end DESC) = 1
),

current_cases AS (
    SELECT
        case_bk,
        registration_date,
        default_date
    FROM prod.npl_common.dim_case
    WHERE is_current_flag
        AND case_bk IN (SELECT case_bk FROM cases_owned)
),

-- Only pairs where we own both cases; anything else stays a cleaned_cases of its own.
migrated_cases AS (
    SELECT
        m.old_case,
        m.new_case,
        n.registration_date AS moved_on
    FROM moved_cleaned_cases AS m
    INNER JOIN current_cases AS n
        ON n.case_bk = m.new_case
    WHERE m.old_case IN (SELECT case_bk FROM cases_owned)
),

-- Which case reports for each cleaned_cases, and over which months.
cases_period AS (
    SELECT
        case_bk AS model_id,
        NULL AS previous_model_id,
        case_bk,
        '1900-01-31'::DATE AS reports_from,
        '9999-12-31'::DATE AS reports_to
    FROM cases_owned
    WHERE case_bk NOT IN (SELECT old_case FROM migrated_cases)
        AND case_bk NOT IN (SELECT new_case FROM migrated_cases)

    UNION ALL

    SELECT
        new_case,
        old_case,
        old_case,
        '1900-01-31'::DATE,
        LAST_DAY(DATEADD(MONTH, -1, moved_on))
    FROM migrated_cases

    UNION ALL

    SELECT
        new_case,
        old_case,
        new_case,
        LAST_DAY(moved_on),
        '9999-12-31'::DATE
    FROM migrated_cases
),

-- One row per cleaned_cases. For a moved cleaned_cases, registration and default come from the earlier of its two
-- cases, which is when the cleaned_cases first reached Intrum.
cleaned_cases AS (
    SELECT
        l.model_id,
        MAX(l.previous_model_id) AS previous_model_id,
        MIN(c.registration_date) AS registration_date,
        MIN(c.default_date) AS default_date
    FROM cases_period AS l
    INNER JOIN current_cases AS c
        ON c.case_bk = l.case_bk
    GROUP BY 1
),

-- The batch, and so the deal name, of the case reporting today.
cleaned_cases_batch AS (
    SELECT
        l.model_id,
        IFF(
            b.deal_source_bk = 'HEI' OR dl.deal_bk IS NULL,
            -- Heimdall is one Atlas deal (HEI-SE25001) over 2,612 Intrum books, so its books are
            -- named vehicle-Intrum id. Every other vehicle has its own Atlas deal, whose id already
            -- reads vehicle-Atlas id (LOK-SE25008 is the book Intrum calls SE25018).
            b.deal_source_bk || '-' || b.servicer_parent_portfolio_bk,
            dl.deal_bk
        ) AS deal_id,
        b.servicer_parent_portfolio_bk AS intrum_id,
        b.batch_bk,
        b.legal_seller_name AS seller_name
    FROM cases_period AS l
    INNER JOIN cases_owned AS o
        ON o.case_bk = l.case_bk
    INNER JOIN prod.npl_common.dim_batch AS b
        ON b.batch_sk = o.batch_sk
    -- Kept as a left join: a batch whose portfolio the warehouse does not know would otherwise vanish.
    LEFT JOIN prod.npl_common.dim_portfolio AS pf
        ON pf.portfolio_sk = b.portfolio_sk
    LEFT JOIN prod.npl_common.dim_deal AS dl
        ON dl.deal_id = pf.deal_id
    WHERE l.reports_to = '9999-12-31'::DATE
),

-- The deal's latest approved asset-index run, from the prod pipeline only.
asset_index_latest_run AS (
    SELECT run_id
    FROM asset_index.approved.runs
    WHERE portfolio_id = $portfolio_id
        AND source_work_uri LIKE 's3://ml-prod-asset-index-work/%'
    QUALIFY ROW_NUMBER() OVER (ORDER BY approved_at DESC) = 1
),

asset_index_case AS (
    SELECT
        a.case_id,
        a.cutoff_date,
        a.currency,
        a.principal_at_cutoff,
        a.legal_balance_at_cutoff,
        a.accrued_interest_at_cutoff,
        a.product_type
    FROM asset_index.approved.cases AS a
    INNER JOIN asset_index_latest_run AS r
        ON r.run_id = a._run_id
),

asset_index_counterparty AS (
    SELECT
        l.case_id,
        MAX(p.birth_year) AS birth_year,
        MAX(p.deceased) AS deceased,
        MAX(p.gender) AS gender
    FROM asset_index.approved.case_counterparty AS l
    INNER JOIN asset_index_latest_run AS r
        ON r.run_id = l._run_id
    INNER JOIN asset_index.approved.counterparties AS p
        ON p._run_id = l._run_id
        AND p.counterparty_id = l.counterparty_id
    GROUP BY 1
),

-- Filled only for cleaned_casess on the seller's DS tape; empty means not on that tape, not false.
asset_index_attribute AS (
    SELECT
        a.entity_id AS case_id,
        MAX(IFF(a.attribute = 'bankruptcy_flag', a.value, NULL)) AS bankruptcy_flag,
        MAX(IFF(a.attribute = 'debt_restructuring_flag', a.value, NULL)) AS debt_restructuring_flag,
        MAX(IFF(a.attribute = 'postal_region', a.value, NULL)) AS postal_region
    FROM asset_index.approved.attributes AS a
    INNER JOIN asset_index_latest_run AS r
        ON r.run_id = a._run_id
    WHERE a.entity_type = 'case'
    GROUP BY 1
),

-- The tape row for each cleaned_cases: under its current case id, or its old one if that is what the tape used.
cleaned_cases_tape AS (
    SELECT
        l.model_id,
        a.case_id AS tape_case_id
    FROM cleaned_cases AS l
    INNER JOIN asset_index_case AS a
        ON a.case_id = l.model_id
        OR a.case_id = l.previous_model_id
    QUALIFY ROW_NUMBER() OVER (PARTITION BY l.model_id ORDER BY (a.case_id = l.model_id) DESC) = 1
),

-- Month-ends from the tape cut-off to the warehouse's latest month-end.
month_base_reference AS (
    SELECT month_end
    FROM (
        SELECT LAST_DAY(DATEADD(
            MONTH,
            ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1,
            DATE_TRUNC(MONTH, (SELECT MIN(cutoff_date) FROM asset_index_case))
        )) AS month_end
        FROM TABLE(GENERATOR(ROWCOUNT => 600))
    )
    WHERE month_end <= (SELECT MAX(month_end) FROM monthly_cases)
),

-- Each cleaned_cases's month-end figures, from whichever case reports for it that month.
monthly_cleaned_cases AS (
    SELECT
        l.model_id,
        d.case_bk AS reported_by_case,
        d.month_end,
        d.outstanding_principal,
        d.outstanding_interest,
        d.outstanding_fees,
        d.outstanding_total,
        d.forbearance_flag,
        v.status_code,
        v.status_description,
        v.closing_date,
        v.closing_code
    FROM cases_period AS l
    INNER JOIN monthly_cases AS d
        ON d.case_bk = l.case_bk
        AND d.month_end BETWEEN l.reports_from AND l.reports_to
    INNER JOIN prod.npl_common.dim_case AS v
        ON v.case_sk = d.case_sk
),

-- Balance in the month the cleaned_cases was registered, where the warehouse has that month.
registration_balance AS (
    SELECT
        m.model_id,
        m.outstanding_principal AS principal_at_registration,
        m.outstanding_total AS balance_at_registration
    FROM monthly_cleaned_cases AS m
    INNER JOIN cleaned_cases AS l
        ON l.model_id = m.model_id
    WHERE m.month_end = LAST_DAY(l.registration_date)
),

-- Collections per cleaned_cases and month, over both cases of a moved cleaned_cases.
cleaned_cases_collection AS (
    SELECT
        l.model_id,
        LAST_DAY(f.collection_date) AS month_end,
        SUM(f.amount) AS collected_in_month
    FROM (SELECT DISTINCT model_id, case_bk FROM cases_period) AS l
    INNER JOIN cases_owned AS o
        ON o.case_bk = l.case_bk
    INNER JOIN prod.npl_common.fct_case_collection AS f
        ON f.case_id = o.case_id_hashed
    GROUP BY 1, 2
),

deal_batch AS (
    SELECT
        batch_sk,
        legacy_capex_date
    FROM prod.npl_common.dim_batch
    WHERE servicer_parent_portfolio_bk = $portfolio_id
),

acquisition AS (
    SELECT MIN(legacy_capex_date) AS acquisition_date
    FROM deal_batch
),

pam_extract AS (
    SELECT
        MAX(_file_path) AS file_path,
        TO_DATE(REGEXP_SUBSTR(MAX(_file_path), 'pam\\.pam\\.pam\\.(\\d{8})', 1, 1, 'e'), 'YYYYMMDD')
            AS extracted_on
    FROM raw.hyperion_intrum_pam.pam
    WHERE _file_path LIKE '%/pam.pam.pam.2%'
),

pam_monthly AS (
    SELECT
        DATE_TRUNC(MONTH, p.period_start_date::DATE) AS collection_month,
        SUM(p.colltotal) AS pam_collected
    FROM raw.hyperion_intrum_pam.pam AS p
    CROSS JOIN pam_extract AS e
    CROSS JOIN acquisition AS q
    WHERE p._file_path = e.file_path
        AND p.pmode_name = 'Real'
        AND COALESCE(p.is_ownership_change, 0) = 0
        AND p.portfolioid = $portfolio_id
        AND p.period_start_date::DATE < DATE_TRUNC(MONTH, e.extracted_on)
        AND p.period_start_date::DATE >= DATE_TRUNC(MONTH, q.acquisition_date)
    GROUP BY 1
),

warehouse_monthly AS (
    SELECT
        DATE_TRUNC(MONTH, f.collection_date) AS collection_month,
        SUM(f.amount) AS warehouse_collected
    FROM prod.npl_common.fct_case_collection AS f
    INNER JOIN deal_batch AS b
        ON b.batch_sk = f.batch_sk
    CROSS JOIN acquisition AS q
    WHERE f.collection_date >= DATE_TRUNC(MONTH, q.acquisition_date)
    GROUP BY 1
),

-- Both sides stop at whichever source ends first, so neither is short only for being older.
base_pam_reconciliation AS (
    SELECT
        p.collection_month,
        p.pam_collected,
        COALESCE(w.warehouse_collected, 0) AS warehouse_collected
    FROM pam_monthly AS p
    LEFT JOIN warehouse_monthly AS w
        ON w.collection_month = p.collection_month
    WHERE p.collection_month <= (SELECT MAX(collection_month) FROM warehouse_monthly)
),

pam_reconciliation AS (
    SELECT
        SUM(pam_collected) AS pam_collected,
        SUM(warehouse_collected) AS warehouse_collected,
        -- Percentages: the warehouse's total above (+) or below (-) PAM's, and the share of PAM's
        -- cash months in which the warehouse has cash too.
        (SUM(warehouse_collected) / NULLIF(SUM(pam_collected), 0) - 1) * 100
            AS collection_reconciliation_total_pct,
        COUNT_IF(pam_collected <> 0 AND warehouse_collected <> 0)
            / NULLIF(COUNT_IF(pam_collected <> 0), 0) * 100 AS collection_month_coverage_pct,
        MIN(collection_month) AS compared_from,
        MAX(collection_month) AS compared_to
    FROM base_pam_reconciliation
)

SELECT
    -- Identifiers and the month; no prefix
    l.model_id,
    l.previous_model_id,                        -- the old 1062 case, for a cleaned_cases Intrum moved to 2080
    SPLIT_PART(l.model_id, '-', 1) AS instance,
    b.deal_id,
    b.intrum_id,
    t.month_end,
    DATEDIFF(MONTH, l.registration_date, t.month_end) AS months_since_registration,  -- negative before

    -- asset_index_: the seller's tape, as at its cut-off; the same on every row
    lt.model_id IS NOT NULL AS in_asset_index,
    a.cutoff_date AS asset_index_cutoff_date,
    a.currency AS asset_index_currency,
    a.principal_at_cutoff AS asset_index_principal_at_cutoff,
    a.legal_balance_at_cutoff AS asset_index_legal_balance_at_cutoff,
    a.accrued_interest_at_cutoff AS asset_index_accrued_interest_at_cutoff,
    INITCAP(a.product_type) AS asset_index_product_type,
    p.birth_year AS asset_index_birth_year,
    p.deceased AS asset_index_deceased,
    p.gender AS asset_index_gender,
    x.bankruptcy_flag AS asset_index_bankruptcy_flag,
    x.debt_restructuring_flag AS asset_index_debt_restructuring_flag,
    x.postal_region AS asset_index_postal_region,

    -- warehouse_: the deal, registration and default; the same on every row
    b.batch_bk AS warehouse_batch_bk,
    b.seller_name AS warehouse_seller_name,
    l.registration_date AS warehouse_registration_date,
    l.default_date AS warehouse_default_date,
    r.principal_at_registration AS warehouse_principal_at_registration,
    r.balance_at_registration AS warehouse_balance_at_registration,

    -- warehouse_: as at this month-end; empty where the warehouse has no row for the month
    m.reported_by_case AS warehouse_reported_by_case,
    m.outstanding_principal AS warehouse_outstanding_principal,
    m.outstanding_interest AS warehouse_outstanding_interest,
    m.outstanding_fees AS warehouse_outstanding_fees,
    m.outstanding_total AS warehouse_outstanding_total,
    m.forbearance_flag AS warehouse_forbearance_flag,
    m.status_code AS warehouse_status_code,
    m.status_description AS warehouse_status_description,
    IFF(m.model_id IS NULL, NULL, COALESCE(m.closing_date <= t.month_end, FALSE)) AS warehouse_is_closed,
    IFF(m.closing_date <= t.month_end, m.closing_code, NULL) AS warehouse_closing_code,
    IFF(m.closing_date <= t.month_end, m.closing_date, NULL) AS warehouse_closing_date,

    -- warehouse_: collections in this month; read warehouse_reconciles_with_pam first
    COALESCE(k.collected_in_month, 0) AS warehouse_collected_in_month,

    -- warehouse_vs_pam_: the warehouse's collections checked against Intrum's own monthly report,
    -- for the whole deal; the same on every row
    ROUND(q.collection_reconciliation_total_pct, 5) AS warehouse_vs_pam_collection_total_pct,
    ROUND(q.collection_month_coverage_pct, 5) AS warehouse_vs_pam_month_coverage_pct,
    COALESCE(
        ABS(q.collection_reconciliation_total_pct) < $max_total_deviation_pct
            AND q.collection_month_coverage_pct > $min_month_coverage_pct,
        FALSE
    ) AS warehouse_reconciles_with_pam
FROM cleaned_cases AS l
CROSS JOIN month_base_reference AS t
CROSS JOIN pam_reconciliation AS q
LEFT JOIN cleaned_cases_batch AS b
    ON b.model_id = l.model_id
LEFT JOIN cleaned_cases_tape AS lt
    ON lt.model_id = l.model_id
LEFT JOIN asset_index_case AS a
    ON a.case_id = lt.tape_case_id
LEFT JOIN asset_index_counterparty AS p
    ON p.case_id = lt.tape_case_id
LEFT JOIN asset_index_attribute AS x
    ON x.case_id = lt.tape_case_id
LEFT JOIN registration_balance AS r
    ON r.model_id = l.model_id
LEFT JOIN monthly_cleaned_cases AS m
    ON m.model_id = l.model_id
    AND m.month_end = t.month_end
LEFT JOIN cleaned_cases_collection AS k
    ON k.model_id = l.model_id
    AND k.month_end = t.month_end
ORDER BY 1, 6
