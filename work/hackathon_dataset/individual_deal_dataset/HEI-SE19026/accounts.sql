-- SE19026 accounts: one row per loan per month-end, from the tape cut-off (Dec 2019) to the latest month.
-- Column prefixes: asset_index_ = seller's tape, warehouse_ = our warehouse.
-- A loan is ours if the warehouse puts one of its cases in an SE19026 batch.
-- Intrum moved 491 loans from system 1062 to 2080, so each has two cases but is one loan here.
-- For a moved loan, model_id is the new case; the old case shows in warehouse_reported_by_case for the months before the move.
-- The 491 pairs are listed below; rebuild them with bridge_check/moved_by_principal.sql.
-- Pairs are matched on principal only; 11 more old cases closed on a move but found no partner with equal principal, so they stay loans of their own.
-- Warehouse payments and the PAM check come from the sandbox build (payments_post_registration.sql); deal_dataset.py adds them.
-- Measured 24 Nov 2026: 9,574 loans, 794,642 rows; 9,292 loans in the asset index.

SET portfolio_id = 'SE19026';
SET asset_index_id = 'SE19026';  -- the deal's id in the asset index

WITH
-- Old case on 1062, new case on 2080, one pair per moved loan.
moved_cleaned_cases AS (
    SELECT
        column1 AS old_case,
        column2 AS new_case
    FROM VALUES
        ('1062-6950453', '2080-2245457'), ('1062-7006792', '2080-1964474'), ('1062-7022732', '2080-1964609'), ('1062-7022734', '2080-1964610'),
        ('1062-7027188', '2080-2245461'), ('1062-7029257', '2080-2167602'), ('1062-7029276', '2080-2167604'), ('1062-7029294', '2080-2167605'),
        ('1062-7033533', '2080-1964810'), ('1062-7033534', '2080-1964811'), ('1062-7033541', '2080-1964812'), ('1062-7033543', '2080-1964813'),
        ('1062-7033544', '2080-1964814'), ('1062-7033546', '2080-1964815'), ('1062-7033547', '2080-1964816'), ('1062-7033549', '2080-1964817'),
        ('1062-7033550', '2080-1964818'), ('1062-7033553', '2080-1964819'), ('1062-7033554', '2080-1964820'), ('1062-7033555', '2080-1964821'),
        ('1062-7033556', '2080-1964822'), ('1062-7033562', '2080-1964823'), ('1062-7033563', '2080-1964824'), ('1062-7033567', '2080-1964825'),
        ('1062-7033570', '2080-1964826'), ('1062-7033571', '2080-2167662'), ('1062-7033572', '2080-1964827'), ('1062-7033574', '2080-1964828'),
        ('1062-7033579', '2080-1964829'), ('1062-7033580', '2080-1997802'), ('1062-7033581', '2080-1964830'), ('1062-7033582', '2080-1964831'),
        ('1062-7033585', '2080-2167663'), ('1062-7033586', '2080-1964832'), ('1062-7033588', '2080-1964833'), ('1062-7033589', '2080-2167664'),
        ('1062-7033591', '2080-2126332'), ('1062-7033592', '2080-1964834'), ('1062-7033598', '2080-1964835'), ('1062-7033599', '2080-1964836'),
        ('1062-7033601', '2080-1964837'), ('1062-7033603', '2080-1964838'), ('1062-7033604', '2080-1964839'), ('1062-7033605', '2080-1964840'),
        ('1062-7033606', '2080-1964841'), ('1062-7033608', '2080-1964842'), ('1062-7033611', '2080-1964843'), ('1062-7033615', '2080-2167665'),
        ('1062-7033616', '2080-1964844'), ('1062-7033617', '2080-1964845'), ('1062-7033618', '2080-1964846'), ('1062-7033621', '2080-1964847'),
        ('1062-7033622', '2080-1964848'), ('1062-7033624', '2080-1964849'), ('1062-7033625', '2080-1964850'), ('1062-7033627', '2080-1964851'),
        ('1062-7033628', '2080-1964852'), ('1062-7033630', '2080-2167666'), ('1062-7033632', '2080-1964853'), ('1062-7033635', '2080-1964854'),
        ('1062-7033636', '2080-1964855'), ('1062-7033640', '2080-1964856'), ('1062-7033641', '2080-2246098'), ('1062-7033642', '2080-1964857'),
        ('1062-7033643', '2080-1964858'), ('1062-7033645', '2080-1964859'), ('1062-7033646', '2080-1964860'), ('1062-7033649', '2080-1964861'),
        ('1062-7033650', '2080-1964862'), ('1062-7033654', '2080-1964863'), ('1062-7033656', '2080-1964864'), ('1062-7034236', '2080-1964875'),
        ('1062-7035816', '2080-1964904'), ('1062-7035817', '2080-1964905'), ('1062-7035818', '2080-1964906'), ('1062-7035819', '2080-1964907'),
        ('1062-7035820', '2080-1964908'), ('1062-7035822', '2080-1964909'), ('1062-7035823', '2080-1964910'), ('1062-7035824', '2080-1964911'),
        ('1062-7037129', '2080-1964942'), ('1062-7040009', '2080-2167787'), ('1062-7040010', '2080-1964963'), ('1062-7040011', '2080-1964964'),
        ('1062-7050170', '2080-1983196'), ('1062-7050268', '2080-2167872'), ('1062-7055396', '2080-1965218'), ('1062-7055397', '2080-1965219'),
        ('1062-7055398', '2080-2168035'), ('1062-7055399', '2080-1965220'), ('1062-7059375', '2080-1965287'), ('1062-7059376', '2080-1965288'),
        ('1062-7059379', '2080-1965289'), ('1062-7059380', '2080-1965290'), ('1062-7059381', '2080-2168105'), ('1062-7059383', '2080-1965291'),
        ('1062-7059384', '2080-1965292'), ('1062-7059385', '2080-1965293'), ('1062-7059386', '2080-2245697'), ('1062-7059387', '2080-1965294'),
        ('1062-7059388', '2080-1965295'), ('1062-7059389', '2080-1997828'), ('1062-7059391', '2080-1965296'), ('1062-7059392', '2080-2168106'),
        ('1062-7059393', '2080-1965297'), ('1062-7059395', '2080-1965298'), ('1062-7059396', '2080-1965299'), ('1062-7059398', '2080-1965300'),
        ('1062-7059400', '2080-2168107'), ('1062-7059401', '2080-1965301'), ('1062-7059402', '2080-1965302'), ('1062-7059408', '2080-1997829'),
        ('1062-7060419', '2080-1965318'), ('1062-7060422', '2080-1965319'), ('1062-7060423', '2080-1965320'), ('1062-7060873', '2080-1965327'),
        ('1062-7060874', '2080-1965328'), ('1062-7060875', '2080-1965329'), ('1062-7060876', '2080-1965330'), ('1062-7060877', '2080-1965331'),
        ('1062-7060880', '2080-1965332'), ('1062-7061058', '2080-1997832'), ('1062-7061059', '2080-1965338'), ('1062-7061061', '2080-2168125'),
        ('1062-7061064', '2080-2168126'), ('1062-7064531', '2080-2214432'), ('1062-7064534', '2080-1983197'), ('1062-7064535', '2080-1965574'),
        ('1062-7065454', '2080-2168254'), ('1062-7067300', '2080-1965620'), ('1062-7067301', '2080-1965621'), ('1062-7067302', '2080-1965622'),
        ('1062-7067303', '2080-1965623'), ('1062-7067306', '2080-1965624'), ('1062-7067308', '2080-1965625'), ('1062-7067309', '2080-1965626'),
        ('1062-7067310', '2080-1965627'), ('1062-7067311', '2080-2168272'), ('1062-7067312', '2080-1965628'), ('1062-7067315', '2080-2168273'),
        ('1062-7067316', '2080-1965629'), ('1062-7067320', '2080-2168274'), ('1062-7068663', '2080-1965672'), ('1062-7070629', '2080-1983198'),
        ('1062-7070633', '2080-2168313'), ('1062-7070904', '2080-1997847'), ('1062-7070905', '2080-1997848'), ('1062-7070961', '2080-1965685'),
        ('1062-7070962', '2080-1965686'), ('1062-7070964', '2080-1965687'), ('1062-7070966', '2080-1965688'), ('1062-7075879', '2080-1997866'),
        ('1062-7080031', '2080-1965859'), ('1062-7080326', '2080-2168565'), ('1062-7081030', '2080-2168570'), ('1062-7083521', '2080-2126357'),
        ('1062-7083652', '2080-1965912'), ('1062-7083653', '2080-2168619'), ('1062-7083654', '2080-1965913'), ('1062-7083655', '2080-2168620'),
        ('1062-7083656', '2080-1965914'), ('1062-7083658', '2080-1965915'), ('1062-7083661', '2080-1965916'), ('1062-7083662', '2080-2168621'),
        ('1062-7083663', '2080-1965917'), ('1062-7083665', '2080-1997880'), ('1062-7083666', '2080-1965918'), ('1062-7083668', '2080-1965919'),
        ('1062-7083669', '2080-2168622'), ('1062-7083670', '2080-1965920'), ('1062-7083671', '2080-1965921'), ('1062-7083672', '2080-1965922'),
        ('1062-7083673', '2080-1965923'), ('1062-7083674', '2080-1965924'), ('1062-7083677', '2080-2168623'), ('1062-7083680', '2080-1965925'),
        ('1062-7083681', '2080-1965926'), ('1062-7083683', '2080-2168624'), ('1062-7083685', '2080-2168625'), ('1062-7083686', '2080-1965927'),
        ('1062-7083687', '2080-1965928'), ('1062-7083692', '2080-1965929'), ('1062-7083693', '2080-1965930'), ('1062-7083694', '2080-2214470'),
        ('1062-7083695', '2080-2168626'), ('1062-7083698', '2080-2168627'), ('1062-7083700', '2080-1965931'), ('1062-7083703', '2080-2168628'),
        ('1062-7083705', '2080-1965932'), ('1062-7083711', '2080-1997881'), ('1062-7083712', '2080-1965933'), ('1062-7083714', '2080-1965934'),
        ('1062-7083956', '2080-1965936'), ('1062-7084063', '2080-1965939'), ('1062-7084064', '2080-1965940'), ('1062-7084068', '2080-1965941'),
        ('1062-7085941', '2080-2126360'), ('1062-7089791', '2080-2245498'), ('1062-7090177', '2080-1965976'), ('1062-7092363', '2080-1966019'),
        ('1062-7092367', '2080-1966020'), ('1062-7092368', '2080-1966021'), ('1062-7092373', '2080-1997888'), ('1062-7092374', '2080-1966022'),
        ('1062-7092375', '2080-1966023'), ('1062-7092382', '2080-1966024'), ('1062-7093123', '2080-1966044'), ('1062-7093127', '2080-1966045'),
        ('1062-7093446', '2080-1966061'), ('1062-7093469', '2080-1966063'), ('1062-7093904', '2080-1966072'), ('1062-7093908', '2080-1966073'),
        ('1062-7093909', '2080-1966074'), ('1062-7093913', '2080-2126393'), ('1062-7093917', '2080-1966076'), ('1062-7095045', '2080-1966095'),
        ('1062-7095417', '2080-1966098'), ('1062-7097270', '2080-1966137'), ('1062-7099942', '2080-1966245'), ('1062-7100927', '2080-1966256'),
        ('1062-7101954', '2080-1966262'), ('1062-7102556', '2080-1983200'), ('1062-7103479', '2080-1966279'), ('1062-7105721', '2080-1966329'),
        ('1062-7105722', '2080-1966330'), ('1062-7105723', '2080-1966331'), ('1062-7105725', '2080-1966332'), ('1062-7105726', '2080-1966333'),
        ('1062-7105729', '2080-1997917'), ('1062-7105732', '2080-1966334'), ('1062-7105733', '2080-1966335'), ('1062-7105736', '2080-1966336'),
        ('1062-7105739', '2080-1966337'), ('1062-7105742', '2080-1966338'), ('1062-7105743', '2080-1966339'), ('1062-7105744', '2080-1966340'),
        ('1062-7105747', '2080-1966341'), ('1062-7105748', '2080-1966342'), ('1062-7105749', '2080-2169130'), ('1062-7105751', '2080-1966343'),
        ('1062-7105752', '2080-1966344'), ('1062-7105756', '2080-1966345'), ('1062-7105762', '2080-1966346'), ('1062-7105765', '2080-1966347'),
        ('1062-7105766', '2080-1997918'), ('1062-7106506', '2080-1966359'), ('1062-7107139', '2080-1966368'), ('1062-7107140', '2080-1997919'),
        ('1062-7107347', '2080-1966374'), ('1062-7107549', '2080-1966379'), ('1062-7110546', '2080-1966403'), ('1062-7110655', '2080-2169237'),
        ('1062-7110658', '2080-1966406'), ('1062-7110661', '2080-1966407'), ('1062-7110664', '2080-1966408'), ('1062-7110668', '2080-1966409'),
        ('1062-7110987', '2080-1966418'), ('1062-7111016', '2080-1966420'), ('1062-7111019', '2080-2169241'), ('1062-7112805', '2080-1966457'),
        ('1062-7118915', '2080-1966465'), ('1062-7118916', '2080-1966466'), ('1062-7118923', '2080-2214528'), ('1062-7119969', '2080-1966491'),
        ('1062-7119976', '2080-1966493'), ('1062-7120631', '2080-1966509'), ('1062-7120632', '2080-2169302'), ('1062-7120982', '2080-1966516'),
        ('1062-7120983', '2080-1966517'), ('1062-7121493', '2080-2245666'), ('1062-7122857', '2080-1966527'), ('1062-7123402', '2080-2247187'),
        ('1062-7123816', '2080-2169381'), ('1062-7123817', '2080-2169382'), ('1062-7127710', '2080-1966689'), ('1062-7128527', '2080-1966708'),
        ('1062-7128528', '2080-1966709'), ('1062-7128531', '2080-1966710'), ('1062-7128533', '2080-1966711'), ('1062-7128536', '2080-1966712'),
        ('1062-7128539', '2080-1966713'), ('1062-7128543', '2080-1966714'), ('1062-7128544', '2080-1966715'), ('1062-7128545', '2080-2169524'),
        ('1062-7128547', '2080-1966716'), ('1062-7128548', '2080-2169525'), ('1062-7128551', '2080-1966717'), ('1062-7128552', '2080-2126409'),
        ('1062-7128554', '2080-1966718'), ('1062-7128562', '2080-2169526'), ('1062-7128565', '2080-1966719'), ('1062-7128566', '2080-1966720'),
        ('1062-7129519', '2080-1983202'), ('1062-7131475', '2080-2169608'), ('1062-7132669', '2080-1966783'), ('1062-7132673', '2080-2169624'),
        ('1062-7132676', '2080-1966784'), ('1062-7132680', '2080-2169625'), ('1062-7132681', '2080-1966785'), ('1062-7132682', '2080-1966786'),
        ('1062-7132686', '2080-1966787'), ('1062-7132687', '2080-1966788'), ('1062-7132688', '2080-1966789'), ('1062-7134539', '2080-1966807'),
        ('1062-7134541', '2080-1966808'), ('1062-7134543', '2080-1966809'), ('1062-7134890', '2080-1966812'), ('1062-7134893', '2080-1966813'),
        ('1062-7134950', '2080-2169673'), ('1062-7135748', '2080-1966840'), ('1062-7136306', '2080-1966845'), ('1062-7136398', '2080-1966846'),
        ('1062-7136399', '2080-1966847'), ('1062-7143889', '2080-1966923'), ('1062-7146376', '2080-1966953'), ('1062-7146700', '2080-1966965'),
        ('1062-7148063', '2080-1966990'), ('1062-7148087', '2080-1966993'), ('1062-7150103', '2080-1967019'), ('1062-7150104', '2080-1967020'),
        ('1062-7150109', '2080-1967021'), ('1062-7150110', '2080-1967022'), ('1062-7150112', '2080-1967023'), ('1062-7150113', '2080-1967024'),
        ('1062-7150117', '2080-1967025'), ('1062-7150122', '2080-1967026'), ('1062-7151607', '2080-1967086'), ('1062-7151900', '2080-1967105'),
        ('1062-7152232', '2080-1967109'), ('1062-7155112', '2080-2170003'), ('1062-7155113', '2080-1967130'), ('1062-7155115', '2080-2126416'),
        ('1062-7155117', '2080-1967131'), ('1062-7155119', '2080-1967132'), ('1062-7155120', '2080-1967133'), ('1062-7155121', '2080-1967134'),
        ('1062-7155122', '2080-2126417'), ('1062-7155124', '2080-1967135'), ('1062-7155126', '2080-1967136'), ('1062-7155128', '2080-1967137'),
        ('1062-7155129', '2080-1967138'), ('1062-7155130', '2080-1967139'), ('1062-7155132', '2080-1967140'), ('1062-7155134', '2080-1967141'),
        ('1062-7155135', '2080-1967142'), ('1062-7155139', '2080-1967143'), ('1062-7155140', '2080-1967144'), ('1062-7155141', '2080-1967145'),
        ('1062-7155142', '2080-1967146'), ('1062-7155143', '2080-1967147'), ('1062-7155145', '2080-1967148'), ('1062-7155147', '2080-1967149'),
        ('1062-7155149', '2080-1967150'), ('1062-7155150', '2080-1967151'), ('1062-7155151', '2080-1967152'), ('1062-7155152', '2080-1967153'),
        ('1062-7155153', '2080-1967154'), ('1062-7155155', '2080-1967155'), ('1062-7155157', '2080-1967156'), ('1062-7155158', '2080-1967157'),
        ('1062-7155160', '2080-1967158'), ('1062-7155161', '2080-1967159'), ('1062-7155163', '2080-1967160'), ('1062-7155164', '2080-2170004'),
        ('1062-7155166', '2080-2126418'), ('1062-7155168', '2080-1967161'), ('1062-7155172', '2080-1997993'), ('1062-7155174', '2080-1967162'),
        ('1062-7155175', '2080-1967163'), ('1062-7155176', '2080-1967164'), ('1062-7155177', '2080-1967165'), ('1062-7155178', '2080-1967166'),
        ('1062-7155181', '2080-2170005'), ('1062-7155183', '2080-1967167'), ('1062-7155187', '2080-2126419'), ('1062-7155188', '2080-1997994'),
        ('1062-7155191', '2080-2170007'), ('1062-7155193', '2080-1967168'), ('1062-7155320', '2080-1967170'), ('1062-7155321', '2080-1967171'),
        ('1062-7155322', '2080-1967172'), ('1062-7155475', '2080-1967175'), ('1062-7157374', '2080-2126421'), ('1062-7157927', '2080-1967215'),
        ('1062-7157930', '2080-1967216'), ('1062-7157932', '2080-2170097'), ('1062-7157934', '2080-1967217'), ('1062-7158803', '2080-1967227'),
        ('1062-7158804', '2080-1967228'), ('1062-7158805', '2080-1967229'), ('1062-7158806', '2080-1967230'), ('1062-7158807', '2080-1967231'),
        ('1062-7158815', '2080-1967232'), ('1062-7161524', '2080-1967252'), ('1062-7161819', '2080-1967264'), ('1062-7161827', '2080-2170160'),
        ('1062-7161829', '2080-2170161'), ('1062-7162170', '2080-1967267'), ('1062-7162557', '2080-1998003'), ('1062-7162950', '2080-1967279'),
        ('1062-7162956', '2080-1967281'), ('1062-7162958', '2080-1967282'), ('1062-7162959', '2080-1967283'), ('1062-7163211', '2080-1967293'),
        ('1062-7163381', '2080-1967295'), ('1062-7165651', '2080-1967321'), ('1062-7165652', '2080-1967322'), ('1062-7165659', '2080-1967323'),
        ('1062-7165661', '2080-1967324'), ('1062-7166730', '2080-2170258'), ('1062-7167058', '2080-2170261'), ('1062-7168208', '2080-2170280'),
        ('1062-7168277', '2080-2170281'), ('1062-7169503', '2080-1967425'), ('1062-7169657', '2080-1967430'), ('1062-7169660', '2080-1967431'),
        ('1062-7171761', '2080-2170339'), ('1062-7175285', '2080-1967486'), ('1062-7175286', '2080-2170433'), ('1062-7175288', '2080-1967487'),
        ('1062-7175289', '2080-1967488'), ('1062-7175295', '2080-2170434'), ('1062-7175296', '2080-1967489'), ('1062-7175304', '2080-2170435'),
        ('1062-7175311', '2080-1967490'), ('1062-7175314', '2080-1967491'), ('1062-7175315', '2080-1967492'), ('1062-7175316', '2080-1967493'),
        ('1062-7175318', '2080-1967494'), ('1062-7175320', '2080-1967495'), ('1062-7175322', '2080-1967496'), ('1062-7175326', '2080-1967497'),
        ('1062-7175329', '2080-1967498'), ('1062-7175330', '2080-1967499'), ('1062-7175331', '2080-1967500'), ('1062-7175332', '2080-1967501'),
        ('1062-7175333', '2080-1967502'), ('1062-7175334', '2080-1967503'), ('1062-7175335', '2080-1967504'), ('1062-7175337', '2080-1967505'),
        ('1062-7175338', '2080-1967506'), ('1062-7175339', '2080-1967507'), ('1062-7175342', '2080-1967508'), ('1062-7175343', '2080-1967509'),
        ('1062-7175344', '2080-1998023'), ('1062-7175345', '2080-1967510'), ('1062-7175346', '2080-1967511'), ('1062-7175348', '2080-2170436'),
        ('1062-7175350', '2080-2126430'), ('1062-7175352', '2080-2126431'), ('1062-7175353', '2080-1967512'), ('1062-7175354', '2080-1967513'),
        ('1062-7175361', '2080-2170438'), ('1062-7175369', '2080-1967514'), ('1062-7175372', '2080-1967515'), ('1062-7175377', '2080-2170440'),
        ('1062-7175391', '2080-1967516'), ('1062-7175514', '2080-1967527'), ('1062-7175515', '2080-1967528'), ('1062-7175516', '2080-1967529'),
        ('1062-7175518', '2080-1967530'), ('1062-7176693', '2080-1967539'), ('1062-7176696', '2080-1967540'), ('1062-7176698', '2080-1967541'),
        ('1062-7176699', '2080-1967542'), ('1062-7176701', '2080-1967543'), ('1062-7176702', '2080-1967544'), ('1062-7176704', '2080-1967545'),
        ('1062-7176707', '2080-1967546'), ('1062-7176728', '2080-1967548'), ('1062-7176732', '2080-1967549'), ('1062-7176735', '2080-1998024'),
        ('1062-7176737', '2080-1967550'), ('1062-7176739', '2080-1967551'), ('1062-7176740', '2080-1967552'), ('1062-7177582', '2080-1998026'),
        ('1062-7177583', '2080-1967560'), ('1062-7179943', '2080-1967601'), ('1062-7179944', '2080-1967602'), ('1062-7180333', '2080-1967620'),
        ('1062-7180405', '2080-1967623'), ('1062-7180410', '2080-1967624'), ('1062-7182341', '2080-1967647'), ('1062-7182381', '2080-1967648'),
        ('1062-7182382', '2080-1967649'), ('1062-7182383', '2080-1967650'), ('1062-7182384', '2080-1967651'), ('1062-7182802', '2080-2126436'),
        ('1062-7182803', '2080-2170639'), ('1062-7183046', '2080-1967674'), ('1062-7208130', '2080-1998083')
),

-- Every month-end balance the warehouse holds for the deal's cases.
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

-- Only pairs where we own both cases; anything else stays a loan of its own.
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

-- Which case reports for each loan, and over which months.
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

-- One row per loan; a moved loan takes its registration and default dates from its old case.
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

-- Each loan's deal and batch, from the case reporting today.
cleaned_cases_batch AS (
    SELECT
        l.model_id,
        IFF(
            b.deal_source_bk = 'HEI' OR dl.deal_bk IS NULL,
            -- Heimdall books are named vehicle-Intrum id; other deals use their Atlas id.
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
    -- Left join, so a batch with an unknown portfolio is not dropped.
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
    WHERE portfolio_id = $asset_index_id
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
        a.other_balances_at_cutoff,
        a.default_date,
        a.origination_date,
        a.product_type,
        a.sub_portfolio
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

-- Tape flags; empty means the tape has no such flag for the loan.
asset_index_attribute AS (
    SELECT
        a.entity_id AS case_id,
        MAX(IFF(a.attribute = 'bankruptcy_flag', a.value, NULL)) AS bankruptcy_flag,
        MAX(IFF(a.attribute = 'debt_restructuring_flag', a.value, NULL)) AS debt_restructuring_flag,
        MAX(IFF(a.attribute = 'enforcement_flag', a.value, NULL)) AS enforcement_flag,
        MAX(IFF(a.attribute = 'legal_title_flag', a.value, NULL)) AS legal_title_flag,
        MAX(IFF(a.attribute = 'postal_region', a.value, NULL)) AS postal_region,
        MIN(IFF(a.attribute = 'limitation_date', TRY_TO_DATE(LEFT(a.value, 10)), NULL)) AS limitation_date,
        MIN(IFF(a.attribute = 'verdict_date', TRY_TO_DATE(LEFT(a.value, 10)), NULL)) AS verdict_date,
        MIN(IFF(a.attribute = 'verdict_application_date', TRY_TO_DATE(LEFT(a.value, 10)), NULL))
            AS verdict_application_date
    FROM asset_index.approved.attributes AS a
    INNER JOIN asset_index_latest_run AS r
        ON r.run_id = a._run_id
    WHERE a.entity_type = 'case'
    GROUP BY 1
),

-- Each loan's tape row, under its current case id or its old one.
cleaned_cases_tape AS (
    SELECT
        l.model_id,
        a.case_id AS tape_case_id,
        IFF(a.case_id = l.model_id, 'same_id', 'moved_loan_old_case') AS match_method,
        NULL AS match_points
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

-- Each loan's month-end figures, from whichever case reports for it that month.
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

-- Balance at the end of the registration month, if the warehouse has that month.
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

-- Asset-index payments per tape case and month.
asset_index_payment AS (
    SELECT
        p.case_id,
        LAST_DAY(p.payment_date) AS month_end,
        SUM(p.payment_amount) AS paid_in_month
    FROM asset_index.approved.payments AS p
    INNER JOIN asset_index_latest_run AS r
        ON r.run_id = p._run_id
    GROUP BY p.case_id, LAST_DAY(p.payment_date)
)

SELECT
    -- Identifiers and the month; no prefix
    l.model_id AS model_id,
    SPLIT_PART(l.model_id, '-', 1) AS instance,
    b.deal_id,
    b.intrum_id,
    t.month_end,
    DATEDIFF(MONTH, l.registration_date, t.month_end) AS months_since_registration,  -- negative before

    -- asset_index_: the seller's tape at its cut-off, the same on every row; empty where a deal's tape lacks it
    lt.tape_case_id IS NOT NULL AS in_asset_index,
    lt.match_method AS asset_index_match_method,  -- how the tape row was found: same_id, or moved_loan_old_case (the tape has the moved loan's old 1062 case)
    lt.match_points AS asset_index_match_points,  -- points a borrower_and_balance pair scored
    lt.tape_case_id AS asset_index_case_id,
    a.sub_portfolio AS asset_index_sub_portfolio,
    a.cutoff_date AS asset_index_cutoff_date,
    a.currency AS asset_index_currency,
    a.principal_at_cutoff AS asset_index_principal_at_cutoff,
    a.legal_balance_at_cutoff AS asset_index_legal_balance_at_cutoff,
    a.accrued_interest_at_cutoff AS asset_index_accrued_interest_at_cutoff,
    a.other_balances_at_cutoff AS asset_index_other_balances_at_cutoff,
    a.default_date AS asset_index_default_date,
    a.origination_date AS asset_index_origination_date,
    INITCAP(a.product_type) AS asset_index_product_type,
    p.birth_year AS asset_index_birth_year,
    p.deceased AS asset_index_deceased,
    p.gender AS asset_index_gender,
    x.bankruptcy_flag AS asset_index_bankruptcy_flag,
    x.debt_restructuring_flag AS asset_index_debt_restructuring_flag,
    x.enforcement_flag AS asset_index_enforcement_flag,
    x.legal_title_flag AS asset_index_legal_title_flag,
    x.postal_region AS asset_index_postal_region,
    x.limitation_date AS asset_index_limitation_date,
    x.verdict_date AS asset_index_verdict_date,
    x.verdict_application_date AS asset_index_verdict_application_date,

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

    -- asset_index_: this month's payments in the asset index
    COALESCE(ap.paid_in_month, 0) AS asset_index_paid_in_month
FROM cleaned_cases AS l
CROSS JOIN month_base_reference AS t
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
LEFT JOIN asset_index_payment AS ap
    ON ap.case_id = lt.tape_case_id
    AND ap.month_end = t.month_end
ORDER BY 1, 5
