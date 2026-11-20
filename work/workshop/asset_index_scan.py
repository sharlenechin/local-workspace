"""Which attributes each deal's seller files in asset-index/ carry, and whether they hold values.

headers() reads HEADERS ONLY: a sheet's first 30 rows, to find its header row. Tapes often
open with a title block, so the header row is the one of those 30 with the most text cells.

fill_rates() reads the cells of the matched columns, in memory, and returns only a number
per column: the share of the sheet's data rows that hold something other than a blank or
a "not available" in any language. No seller value is kept, printed or returned.
"""

from __future__ import annotations

import csv
import io
import re
import warnings
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).parent / "asset-index"
TABULAR = {".csv", ".xlsx", ".xlsm", ".xls", ".xlsb"}
SCAN_ROWS = 30


def _is_text(v) -> bool:
    if v is None or isinstance(v, (int, float)) and not isinstance(v, bool):
        return False
    s = str(v).strip()
    # A date or number typed as text is a value, not a header.
    return bool(s) and not re.fullmatch(r"[\d\s.,:/%+-]+", s)


def _header_row(rows: list[list]) -> tuple[int, list[tuple[int, str]]]:
    """(row index, [(column index, header)]) of the row with the most text cells; ties go
    to the first, which is the usual header."""
    best_at, best = 0, []
    for i, row in enumerate(rows):
        texts = [(c, str(v).strip()) for c, v in enumerate(row) if _is_text(v)]
        if len(texts) > len(best):
            best_at, best = i, texts
    return best_at, best


def _csv_dialect(path: Path) -> tuple[str, str]:
    """(encoding, delimiter), sniffed from the first 200 KB."""
    raw = path.read_bytes()[:200_000]
    enc = "latin-1"
    for e in ("utf-8-sig", "cp1252"):
        try:
            raw.decode(e)
            enc = e
            break
        except UnicodeDecodeError:
            continue
    # A cut in the middle of a multi-byte character is not a wrong encoding.
    sample = "\n".join(raw.decode(enc, errors="ignore").splitlines()[:SCAN_ROWS])
    try:
        delim = csv.Sniffer().sniff(sample, delimiters=";,\t|").delimiter
    except csv.Error:
        delim = ";" if sample.count(";") > sample.count(",") else ","
    return enc, delim


def _csv_rows(path: Path) -> list[list]:
    enc, delim = _csv_dialect(path)
    with open(path, encoding=enc, errors="replace", newline="") as f:
        return [row for _, row in zip(range(SCAN_ROWS), csv.reader(f, delimiter=delim))]


def _sheets(path: Path) -> dict[str, list[list]]:
    """First SCAN_ROWS rows of every sheet, as lists of cells."""
    ext = path.suffix.lower()
    if ext == ".csv":
        return {"": _csv_rows(path)}
    if ext in {".xlsx", ".xlsm"}:
        import openpyxl

        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
        try:
            return {
                ws.title: [list(r) for r in ws.iter_rows(max_row=SCAN_ROWS, values_only=True)]
                for ws in wb.worksheets
            }
        finally:
            wb.close()
    engine = {".xls": "xlrd", ".xlsb": "pyxlsb"}[ext]
    frames = pd.read_excel(path, sheet_name=None, header=None, nrows=SCAN_ROWS, engine=engine)
    return {name: df.where(df.notna(), None).values.tolist() for name, df in frames.items()}


def headers(root: Path = ROOT) -> tuple[pd.DataFrame, pd.DataFrame]:
    """(headers, unreadable): one row per header found, and every file that could not be read."""
    found, failed = [], []
    for deal_dir in sorted(p for p in root.iterdir() if p.is_dir()):
        for path in sorted(deal_dir.rglob("*")):
            if path.suffix.lower() not in TABULAR or "_meta" in path.parts:
                continue
            rel = str(path.relative_to(deal_dir))
            try:
                sheets = _sheets(path)
            except Exception as e:  # noqa: BLE001 -- report every unreadable file, never stop
                # An .xlsx/.xlsb is a zip; one that opens as an OLE container instead has been
                # encrypted with rights management (DRM) and only Excel with access opens it.
                ole = path.read_bytes()[:8] == b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"
                why = ("DRM-protected (encrypted): open it in Excel with access"
                       if ole and path.suffix.lower() in {".xlsx", ".xlsm", ".xlsb"}
                       else f"{type(e).__name__}: {e}"[:200])
                failed.append((deal_dir.name, rel, why))
                continue
            for sheet, rows in sheets.items():
                at, cols = _header_row(rows)
                for col, h in cols:
                    found.append((deal_dir.name, rel, sheet, at, col, h))
    return (
        pd.DataFrame(found, columns=["deal_id", "file", "sheet", "header_row", "col", "header"]),
        pd.DataFrame(failed, columns=["deal_id", "file", "error"]),
    )


# ---------------------------------------------------------------------------------------
# Matching headers to attributes
# ---------------------------------------------------------------------------------------
# Each attribute is (include, exclude): a header carries the attribute when it matches
# `include` and not `exclude`. Both are regexes over the normalised header (lowercase,
# camelCase split, punctuation to spaces), and they include the local terms of Sections A
# and B, since tapes arrive in Swedish, German, Portuguese, Italian, Spanish and more.
# Short tokens (iva, dpd, ccj...) are word-bounded so they do not match inside words.
NOT_BALANCE_PART = r"princip|capital|kapital|interest|ränta|zins|juros|interess|fee|cost|avgift|geb[uü]hr|kosten|spese|gastos|despesa"
PATTERNS: dict[str, tuple[str, str | None]] = {
    # --- Section B: borrower ---
    "age": (r"\bage\b|birth|f[öo]delse|[åa]lder|geburt|\balter\b|\bidade\b|nascimento|\bet[àa]\b|nascita|\bedad\b|fecha nac|syntym|f[øo]dsel|geboorte|leeftijd", r"debt age|age of debt|age range debt|aging|ageing|vintage|mob\b"),
    "gender": (r"gender|\bsex\b|\bk[öo]n\b|geschlecht|\bsexo\b|sesso|sukupuoli|\bk[øo]n\b|geslacht|is male|\bsexe\b", None),
    "town": (r"\btown\b|\bcity\b|\bort\b|stadt|wohnort|localidad|localidade|cidade|\bcomune\b|citt[àa]|municip|poblaci|kommun|kunta|woonplaats|\bville\b|postort|kaupunki", None),
    "city_region": (r"region|\bzip\b|postal|post ?code|postnummer|postnr|\bplz\b|bundesland|provinc|distrito|\bcap\b|codice postale|c[óo]digo postal|\bccaa\b|\bl[äa]n\b|county|\bstate\b|kanton|voivod|wojew|postinumero", r"status|state code"),
    "has_phone_number": (r"phone|telefon|\btel\b|\bmobile|\bmobil\b|m[óo]vil|cellulare|tel[ée]fono|puhelin|telephone|handy", None),
    "has_email": (r"e ?mail|correo|s[äa]hk[öo]posti|e ?post\b", None),
    "individual_vs_corporate": (r"customer type|client type|debtor type|borrower type|person type|legal form|corporate|individual|company|privat|f[öo]retag|\bfirma\b|particular|empresa|persona fisica|giuridica|tipo persona|natural person|jur[íi]dic|legal entity|\bsme\b|consumer|business", r"name|address|number|\bid\b|price|fiscal|parent"),
    "deceased_flag": (r"deceas|\bdead\b|death|avliden|\bd[öo]d\b|verstorb|\btod\b|falecid|[óo]bito|decedut|fallecid|kuollut|\bd[øo]d\b|overleden|d[ée]c[èe]d", None),
    "has_codebtor": (r"co ?debtor|codebtor|joint|second debtor|co ?borrower|med ?l[åa]nt|mitschuld|mitantrag|co ?devedor|cointestat|codeudor|holder 2|borrower 2|debtor 2|number of debtors|nr of debtors|\bn debtors|debtors count|additional debtor|co ?applicant|weitere schuldner", None),
    "has_guarantor": (r"guarant|surety|borgen|b[üu]rg|fiador|fideiuss|garante|avalista|\baval\b|takaaja|kausjon", None),
    "has_multiple_cases": (r"multi ?debtor|multidebtor|multiple|cases per|accounts per|loans per|number of (cases|accounts|loans) per|nr of (cases|accounts)", None),
    "employment_type": (r"employ|occupation|profession|\bjob\b|anst[äa]ll|besch[äa]ftig|beruf|arbeitgeber|emprego|profiss|occupaz|lavoro|empleo|ocupaci|situaci[óo]n laboral|pension|\bty[öo]|employer", None),
    "net_income": (r"income|salary|\bwage|inkomst|\bl[öo]n\b|einkommen|gehalt|rendimento|sal[áa]rio|reddito|stipendio|ingreso|\btulot\b|indkomst|inntekt", None),
    "credit_score": (r"score|rating|bonit|schufa|kreditbetyg|scoring|merito", None),
    "vulnerable_flag": (r"vulnerab|s[åa]rbar|schutzbed", None),
    # --- Section B: dates ---
    "origination_date": (r"originat|open date|opening date|date opened|account open|\bopen year\b|disburs|contract date|agreement date|loan date|start date|inception|utbetalning|abschluss|vertragsdatum|vertragsbeginn|origina[çc][ãa]o|erogazione|formaliz|apertura|first draw|signing date|data contrat|fecha contrat|data stipula", r"originator|original (balance|amount|principal|capital|creditor)"),
    "default_date": (r"default date|date of default|default\b(?!.*(balance|amount|flag|rate))|charge ?off|chrg off|write ?off date|woff date|termination|denounc|upps[äa]g|f[öo]rfall|k[üu]ndig|incumprimento|decadenza|impago|incumplimiento|terminat|acceleration|vencimiento anticipado|first unpaid|first missed|fecha (de )?(entrada en )?mora|data (di )?default|\bdpd ?90|dat chrg", r"balance|amount|saldo|rate|value|total|band"),
    "debt_age": (r"debt age|age of debt|since default|\bageing\b|\baging\b|years in default|months in default", None),
    "cut_off_date": (r"(cut ?off|cutoff).*(date|datum|fecha|data)|^cut ?off$|^cutoff$|stichtag|brytdatum|data de corte|fecha (de )?corte|data corte|reference date|data (di )?riferimento|extraction date|extract date|snapshot date|as of date|as at date|report(ing)? date|data date|fecha (de )?extracci", None),
    "registration_date": (r"registration|registr|[üu]bertragung|cession|cess[ãa]o|cessione|cesi[óo]n|transfer date|boarding|onboard|placement date|assignment date|take ?over|import date|load date|date registered", r"balance|amount|saldo|principal|interest|fee|cost|cciaa|guarantee|id base|contagem|province|\bdca\b|pre registration|post registration|regist(er|ry) (number|id)|registration (number|no|id|code)|registry"),
    "last_payment_date": (r"last pay|latest payment|last paid|last receipt|last collection|last instal|last transaction|date of last|senaste betal|letzte zahl|[úu]ltimo pag|data ultimo|fecha (del )?[úu]ltimo|\blpd\b|viimeinen maksu|sidste betal|laatste betaling|last pmt", None),
    # --- Section B: balances ---
    "registration_balance": (r"registration balance|balance at registration|balance at (transfer|cession|boarding|placement)|transfer balance|boarding balance|placement balance|saldo (na |alla |a la )?cess|saldo (de )?cesi|registration (total|gbv|amount)", None),
    "cut_off_balance": (r"balance|saldo|outstanding|forderung|\bskuld|restskuld|\bgbv\b|total debt|debt amount|amount due|amount outstanding|\bexposure|\bob\b|deuda|importe pendiente|debito residuo|d[íi]vida|velka|gjeld|g[æa]ld|schuld|totalt|claim amount|total amount", NOT_BALANCE_PART + r"|registration|default|original|initial|woff|write|limit|\bdate\b|range|bucket|band|avg|average|min|max|ticket|stress|size|\breg\b"),
    "registration_principal": (r"(registration|transfer|cession|boarding).*(princip|capital)|(princip|capital).*(registration|transfer|cession)", None),
    "cut_off_principal": (r"princip|\bcapital|kapital|hauptforderung|capitale|nominal|\bsr of princ", r"registration|transfer|original|initial|woff|write|received|paid|repaid|repayment|12m|range|bucket|band|avg|average|share|ratio|\bdate\b|guarantee|rate"),
    "registration_interest": (r"(registration|transfer|cession|boarding).*(interest|ränta|zins|juros|interess)", None),
    "cut_off_interest": (r"interest|r[äa]nta|\bzins|juros|interess|intereses|\bkorko|\brente\b|verzugszins", r"rate|registration|transfer|\%|type|tipo|paid|received|\bdate\b"),
    "registration_fee": (r"(registration|transfer|cession|boarding).*(fee|cost|avgift|geb[uü]hr|kosten)", None),
    "cut_off_fee": (r"\bfees?\b|\bcosts?\b|avgift|geb[üu]hr|kosten|comiss|despesa|\bspese\b|gastos|kulut|gebyr|\bcharges?\b|outlay|court cost|legal cost", r"servic|of collection|execution|interim|mark ?up|\blcc\b|registration|transfer|commission|price|pricing|rate|\%|chrg off|charge ?off"),
    "default_balance": (r"default balance|balance at default|(saldo|balance|amount).*(default|impago|incumprimento)|charge ?off (balance|amount)|woff initial|write ?off (balance|amount)|balance woff|k[üu]ndigungs(saldo|betrag)|termination (balance|amount)", None),
    "legal_claim_amount": (r"claim|forderungsbetrag|gesamtforderung|pretesa|importe reclamado|montante reclamado|fordran|claimed|reclam|cr[ée]ance", r"status|date|number|\bid\b|type|disclaim|vat"),
    "original_amount": (r"original|initial|granted|loan amount|credit amount|financed|ursprung|l[åa]nebelopp|kreditbetrag|kreditsumme|montante inicial|importo originario|importe inicial|importo erogato|importe (concedido|formalizado)|disbursed amount", r"woff|write|default|date|creditor|originator|lender|currency|\bid\b|number"),
    "interest_rate": (r"interest rate|\brate\b|zinssatz|r[äa]ntesats|taxa|tasso|tipo (de )?inter[ée]s|\btan\b|\btaeg\b|\btae\b|\bapr\b|effective rate|nominal rate|korkoprosentti", r"exchange|\bfx\b|recovery|collection|success|liquidation|cure|discount|default rate|\birr\b|dividend|\becb\b"),
    # --- Section B: product and deal ---
    "purchase_price": (r"purchase price|\bprice\b|\bpris\b|\bpreis\b|kaufpreis|k[öo]peskilling|pre[çc]o|prezzo|precio", r"prior|previous|historic|unit price|fix price|\birr\b|putback"),
    "prior_purchase_price": (r"(prior|previous|original|historic|acquisition|acquired) .*(price|cost)|price paid|cost of acquisition|purchase cost", None),
    "prior_capex_date": (r"acquisition date|date acquired|acquired date|purchase date|date of purchase|\bcapex\b|f[öo]rv[äa]rv|erwerbs|data de aquisi|data di acquisto|fecha de adquisi|year acquired|bought date|date bought", None),
    "product_type": (r"product|produkt|\btuote|produto|prodotto|producto|loan type|credit type|contract type|kreditart|branch|facility type|account type|tipo operaz|tipo de (cr[ée]dito|contrato|pr[ée]stamo)|l[åa]netyp|kredittyp", r"\bid\b|code$|number"),
    "seller_name": (r"seller|originator|cedent|creditor|client name|bank name|bank of origin|lender|s[äa]ljare|borgen[äa]r|gl[äa]ubiger|verk[äa]ufer|cedente|acreedor|entidad|mandant|kreditgiver", r"number|\bid\b|code|ref|date|pretesa"),
    "pricing_segment": (r"pricing segment|segment|sale segment|valuation segment|\bpool\b|sub ?portfolio|tranche", None),
    "deal_flow_type": (r"deal type|\bflow\b|forward|one ?off|transaction type|aff[äa]rstyp|transaktionsart|tipo de opera|tipo di operaz", None),
    "country": (r"country|\bland\b|pa[íi]s\b|paese|\bnation|countrycode|\bmaa\b|\bpays\b", None),
    "case_count_at_cut_off": (r"^(cases|accounts|accs|loans|contracts)$|number of (cases|accounts|loans|contracts)|no of (cases|accounts|loans)|nr of (cases|accounts|loans)|count of|# ?(cases|accounts|loans)|antal (\w+ )?(ärenden|konton|lån)|anzahl|numero (pratiche|posizioni|contratti)|n º|nº|n\.º", r"schuldner"),
    "case_count_at_registration": (r"(registration|transfer|cession|boarding).*(cases|accounts|count|number)|(cases|accounts) (at|on) (registration|transfer)", None),
    "currency": (r"currency|\bvaluta\b|w[äa]hrung|moeda|moneda|divisa|\bccy\b|\bcur\b|valuutta|devise", None),
    "account_status": (r"status|\bstate\b|open closed|\bclosed\b|closing|\bis open\b|\bactive\b|\btila\b|\bstato\b|\bestado\b|zustand|\baktiv", r"marital|employment|residential|legal|bankrupt|insolv|block|civil|occupation|state code|county|work|risk|enforcement|guarantee|proced"),
    "days_past_due": (r"\bdpd\b|days past due|days overdue|days in arrears|arrears days|d[íi]as (de )?(atraso|impago)|giorni.*scad|dagar.*f[öo]rfall|verzugstage|overdue days|past due|\barrears\b", r"interest"),
    # --- Section B: collateral ---
    "has_collateral": (r"collateral|secured|\bsecurity\b|s[äa]kerhet|sicherheit|garantia|garanzia|garant[íi]a|mortgage|hipotec|ipoteca|pledge|\bpant\b|property|immobil|real estate|\blien\b|vakuus", r"social security|security number"),
    "collateral_value": (r"(collateral|security|property|mortgage|asset|immobil|garanzia|garant[íi]a|garantia|s[äa]kerhet|sicherheit).*(value|valor|valore|wert|v[äa]rde)|valuation|appraisal|perizia|tasaci[óo]n|avalia[çc][ãa]o|market value|\bfjv\b|\bomv\b", r"segment"),
    "collateral_type": (r"(collateral|security|property|mortgage|asset|garanzia|garant[íi]a|garantia|immobil|s[äa]kerhet|sicherheit).*(type|tipo|\bart\b|\btyp\b)|property type|asset type", r"security number"),
    # --- Section B: collections (the derived ones come from these two signals) ---
    "payer_flag": (r"\bpayer|paying|has paid|made payment|ever paid", None),
    "payment_plan_flag": (r"payment plan|repayment plan|instal+ment plan|arrangement|avbetalning|ratenzahl|ratenvereinb|plano de pag|piano di rientro|plan de pagos|acuerdo de pago|promise to pay|\bptp\b|maksusuunnitelma|afdragsordning|betalingsregeling|payment agreement", r"voluntary arrangement"),
    "third_party_managed_flag": (r"\bdca\b|collection agency|inkasso|ag[êe]ncia de cobran|agenzia|agencia de recobro|recobro|placed with|placement|3rd party|third party", r"cost|fee|price|kosten"),
    "current_servicer_name": (r"servicer|dca name|agency name|collection agency|inkassoombud|inkassodienst|\bgestor|recobro|collector name", r"fee|cost|mark ?up|price|\bid\b|code"),
    "prior_servicer_count": (r"placements|number of (dca|servicers|agencies)|\bn dca|dca placements|times placed|previous (agencies|servicers|dca)|prior (agencies|servicers)", None),
    "npl_backstop_flag": (r"backstop", None),
    # --- Section A ---
    "limitation_date": (r"limitation|statute|prescri|preskrip|verj[äa]hr|vanhent|foreld|for[æa]ld|verjaring|przedawn|time ?bar", r"final|lopullinen"),
    "final_limitation_date": (r"final limitation|lopullinen|absolute limitation", None),
    "enforcement_authority_flag": (r"\bkfm\b|kronofogd|enforcement|betalningsf[öo]rel|utm[äa]tning|bailiff", None),
    "debt_restructuring_flag": (r"skuldsaner|debt restructuring|debt rescheduling|\bdr flag\b|\bdr\b|debt sanitation", None),
    "bankruptcy_flag": (r"bankrupt|konkurs|faillis|faillite|upad[łl]|ptoch|insolv|sequestration", None),
    "enforcement_flag": (r"ulosotto|enforcement|esecuzion|pignoram|precetto|execution|attachment|bailiff", r"fee|cost|price"),
    "debt_adjustment_flag": (r"velkaj[äa]rjest|debt adjustment|debt restructuring|debt rescheduling", None),
    "attachment_flag": (r"utlegg|attachment|garnish|\blevy\b|l[øo]nnstrekk", None),
    "debt_settlement_flag": (r"gjeldsordning|debt settlement|debt scheme", None),
    "bailiff_court_flag": (r"foged|bailiff|enforcement court|udl[æa]g|fundament", None),
    "debt_relief_flag": (r"g[æa]ldssaner|debt relief|\bdr flag\b|\bdro\b|\bdr\b", None),
    "titled_flag": (r"titul|\btitel|\btitle|vollstreckungsbescheid|exekutionstitel|judgment|judgement|\bvb\b", r"\bdate\b|datum|titular|titulariza"),
    "insolvency_flag": (r"insolv|konkurs|concurso|insolv[êe]nc|bankrupt|segunda oportunidad|exonera", r"\bdate\b|datum"),
    "insolvency_date": (r"insolv.*(date|datum|er[öo]ffnung)|(date|datum).*insolv|insolvenzer[öo]ffnung", None),
    "title_date": (r"(title|titel|titul|vollstreckungsbescheid|judgment|judgement).*(date|datum)|(date|datum).*(title|titel|titul|judgment)", None),
    "address_unknown_flag": (r"unknown|unbekannt|untraceable|verzogen|no address|gone away|untraced|nicht ermittelbar|\btrac(e|ing)\b", None),
    "debt_enforcement_stage": (r"betreibung|enforcement stage|zahlungsbefehl|pf[äa]ndung|debt enforcement|legal stage|legal phase|collection phase", None),
    "loss_certificate_flag": (r"verlustschein|loss certificate|acte de d[ée]faut|certificate of loss|\bvs\b", None),
    "statutory_debt_restructuring_flag": (r"\bwsnp\b|schuldsaner|debt restructuring|\bmsnp\b", None),
    "bailiff_flag": (r"deurwaarder|bailiff|beslag|komornik|egzekuc|enforcement", r"fee|cost"),
    "collective_debt_settlement_flag": (r"collectieve schuld|r[èe]glement collectif|collective debt|schuldbemiddeling|\bcsr\b|\brcd\b", None),
    "judgment_flag": (r"vonnis|jugement|judgment|judgement", None),
    "enforceable_title_flag": (r"titre ex[ée]cutoire|enforceable title|enforcement title|injonction|\btitle|titled", None),
    "overindebtedness_flag": (r"surendett|over ?indebt|\bbdf\b|banque de france", None),
    "collective_proceedings_flag": (r"proc[ée]dure collective|redressement|liquidation judiciaire|sauvegarde|insolv|bankrupt", None),
    "judicialised_flag": (r"judicial|litig|\blegal\b|\bcourt\b|monitorio|executivo|injun[çc][ãa]o|tribunal|juzgado|demanda|procedimiento|judici", r"legal (entity|form|name|buyer|owner|seller|type|status)|cost|fee|lien|guarantee|counterparty"),
    "injunction_flag": (r"decreto|ingiuntiv|injunction|monitor", None),
    "injunction_date": (r"(decreto|ingiuntiv|injunction).*(date|data)|(date|data) .*(decreto|ingiuntiv)", None),
    "judicial_liquidation_flag": (r"liquidazione giudiziale|fallimento|bankrupt|insolv|concorsual", None),
    "over_indebtedness_flag": (r"sovraindebit|over ?indebt", None),
    "debt_protection_flag": (r"katseli|debt settlement|out of court|\b3869\b", None),
    "payment_order_flag": (r"diatagi|payment order|order for payment", None),
    "county_court_judgment_flag": (r"\bccj\b|county court|judgment|judgement|\bdecree\b", None),
    "individual_voluntary_arrangement_flag": (r"\biva\b|\bdro\b|voluntary arrangement|debt relief order|trust deed", r"partita"),
    "statute_barred_flag": (r"statute|barred|limitation|prescri", None),
    "debt_management_company_flag": (r"\bdmc\b|debt management|stepchange|payplan", None),
    "unenforceable_flag": (r"unenforce|\bue flag\b|\bcca\b|litigation (restricted|hold)", None),
    "court_order_flag": (r"nakaz|\bepu\b|court order|payment order|tytu[łl]|wyrok|judgment|judgement", None),
}

# The two signals every collection attribute is built from.
PAYMENT_AMOUNT = (
    r"payment|collection|collected|\bpaid\b|repayment|inbetal|betalning|zahlung|pagamento|"
    r"\bpago|cobro|incass|recaud|kassafl|cash ?flow|recover|liquidat|receipt|maksu|indbetal|"
    r"\bcash\b|remittance|\bliq\b",
    r"\bdate\b|datum|fecha|\bdata\b|\bref|type|plan|method|status|\bid\b|code|count|number|"
    r"\bno\b|frequency|\bday|channel|last|first|instal|fee|cost|agency|rate|curve|forecast|target",
)
PAYMENT_WHEN = (
    r"payment date|transaction date|booking date|value date|paid date|collection date|"
    r"betalningsdatum|zahlungsdatum|buchungsdatum|data (de |di )?pagamento|fecha (de )?pago|"
    r"fecha cobro|data incasso|data valuta|fecha valor|^month$|^period$|\bmob\b|^date$|"
    r"payment month|collection month|booking month|kassafl|transaction month|maksup[äa]iv",
    None,
)
PRE_REGISTRATION_FLAG = (r"pre ?registration|post ?registration|before registration|after registration", None)
ID = (r"case id|casecode|account (id|number|no)|loan (id|number|no)|contract (id|number|no)|"
      r"model id|debtor id|customer id|client number|reference number|\bref\b|system id|"
      r"aktnr|kontonummer|vertragsnummer|n[úu]mero de (contrato|cuenta)|numero (pratica|contratto)", None)


def normalise(header: str) -> str:
    h = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", str(header))
    return re.sub(r"[^0-9a-zäöåüßéèêàáâãíóôõúñçøæł%]+", " ", h.lower()).strip()


def _hits(norm: pd.Series, spec: tuple[str, str | None]) -> pd.Series:
    inc, exc = spec
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)  # groups in a pattern are only for grouping
        hit = norm.str.contains(inc, regex=True)
        if exc:
            hit &= ~norm.str.contains(exc, regex=True)
    return hit


SIGNALS = {
    **PATTERNS,
    "_payment_amount": PAYMENT_AMOUNT,
    "_payment_when": PAYMENT_WHEN,
    "_pre_registration_flag": PRE_REGISTRATION_FLAG,
    "_id": ID,
}


def hits(hdr: pd.DataFrame) -> pd.DataFrame:
    """Every (deal, attribute, column) match: one row per header that carries an attribute."""
    hdr = hdr.assign(norm=hdr.header.map(normalise))
    parts = [hdr[_hits(hdr.norm, spec)].assign(attribute=attr) for attr, spec in SIGNALS.items()]
    return pd.concat(parts, ignore_index=True).drop(columns="norm")


# Derived attributes, and the attributes or signals each can be built from (any one option).
DERIVED = {
    "debt_age": [["default_date"]],
    "insolvency_age": [["insolvency_date"]],
    "title_age": [["title_date"]],
    "injunction_age": [["injunction_date"]],
    "monthly_collection_sum": [["_payment_amount", "_payment_when"]],
    "monthly_collection_count": [["_payment_amount", "_payment_when"]],
    "collection_months_pre_cut_off": [["_payment_amount", "_payment_when"]],
    "total_collections_pre_cut_off": [["_payment_amount", "_payment_when"]],
    "paying_case_count_pre_cut_off": [["_payment_amount", "_payment_when"]],
    "payer_flag": [["_payment_amount", "_payment_when"]],
    # Before registration needs a registration date or a pre/post flag to split on.
    "collection_months_pre_registration": [["_payment_amount", "_payment_when", "registration_date"], ["_payment_amount", "_pre_registration_flag"]],
    "paying_case_count_pre_registration": [["_payment_amount", "_payment_when", "registration_date"], ["_payment_amount", "_pre_registration_flag"]],
    # After registration is only on a tape that flags it (Intrum benchmark files).
    "collection_months_post_registration": [["_payment_amount", "_pre_registration_flag"]],
    "paying_case_count_post_registration": [["_payment_amount", "_pre_registration_flag"]],
    # One row per case, so any case id gives the count at cut-off.
    "case_count_at_cut_off": [["_id"]],
    "case_count_at_registration": [["_id", "registration_date"]],
}


def matches(hdr: pd.DataFrame) -> pd.DataFrame:
    """One row per (deal, attribute) found, with up to three headers that carried it."""
    rows = []
    for (deal, attr), g in hits(hdr).groupby(["deal_id", "attribute"], sort=False):
        first_three = list(dict.fromkeys(g.header.str.strip()))[:3]
        rows.append((deal, attr, " | ".join(first_three), g.file.iloc[0]))
    found = pd.DataFrame(rows, columns=["deal_id", "attribute", "headers", "example_file"])

    # Derived attributes: built from columns the tape does carry.
    have = set(zip(found.deal_id, found.attribute))
    extra = []
    for attr, options in DERIVED.items():
        for deal in found.deal_id.unique():
            if (deal, attr) in have:
                continue
            for needs in options:
                if all((deal, n) in have for n in needs):
                    extra.append((deal, attr, "(derived from " + " + ".join(n.strip("_") for n in needs) + ")", None))
                    break
    found = pd.concat([found, pd.DataFrame(extra, columns=found.columns)], ignore_index=True)
    return found[~found.attribute.str.startswith("_")]


# ---------------------------------------------------------------------------------------
# Whether a matched column holds anything
# ---------------------------------------------------------------------------------------
# Every way a seller writes "nothing here", compared after lowercasing and trimming. Tapes
# arrive in many languages, so "not available" and "unknown" are listed in each of them.
NULL_LIKE = {
    "", "nan", "nat", "none", "null", "nil", "na", "n/a", "n.a.", "n.a", "#n/a", "#na",
    "#value!", "#ref!", "#div/0!", "-", "--", "---", "?", ".", "x", "n/d", "nd", "n.d.",
    "not available", "not applicable", "unknown", "missing", "no data", "blank", "empty",
    "tbd", "tbc", "0000-00-00", "00.00.0000",
    # Swedish, Norwegian, Danish
    "saknas", "ej tillgänglig", "okänd", "uppgift saknas", "ikke tilgjengelig", "ukjent",
    "ikke tilgængelig", "ukendt",
    # Finnish
    "ei saatavilla", "tuntematon", "ei tiedossa",
    # German
    "nicht verfügbar", "unbekannt", "k.a.", "k. a.", "keine angabe", "keine angaben",
    # Dutch
    "niet beschikbaar", "onbekend",
    # French
    "non disponible", "inconnu", "nc", "n.c.", "non renseigné",
    # Portuguese
    "não disponível", "nao disponivel", "desconhecido", "sem informação", "sem informacao",
    # Italian
    "non disponibile", "sconosciuto", "non noto",
    # Spanish
    "no disponible", "desconocido", "sin dato", "sin datos", "sin información",
    "sin informacion",
    # Polish, Greek
    "brak", "brak danych", "nieznany", "μη διαθέσιμο", "άγνωστο",
}


def useful(v) -> bool:
    """True when a cell holds a value rather than a blank or a 'not available'."""
    if v is None or (isinstance(v, float) and v != v):
        return False
    return str(v).strip().lower() not in NULL_LIKE


def _rows_below(path: Path, sheet: str, header_row: int):
    """Every row below the header row, as a list of cells."""
    ext = path.suffix.lower()
    if ext == ".csv":
        enc, delim = _csv_dialect(path)
        with open(path, encoding=enc, errors="replace", newline="") as f:
            for i, row in enumerate(csv.reader(f, delimiter=delim)):
                if i > header_row:
                    yield row
        return
    if ext in {".xlsx", ".xlsm"}:
        import openpyxl

        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
        try:
            yield from wb[sheet].iter_rows(min_row=header_row + 2, values_only=True)
        finally:
            wb.close()
        return
    engine = {".xls": "xlrd", ".xlsb": "pyxlsb"}[ext]
    df = pd.read_excel(path, sheet_name=sheet, header=None, skiprows=header_row + 1, engine=engine)
    yield from df.itertuples(index=False)


CACHE = Path(__file__).parent / ".cache" / "asset_index_fill_rates.json"


def _sheet_fill(path: Path, sheet: str, header_row: int, cols: list[int]) -> dict[int, float | None]:
    """Fill rate of each column: useful cells / data rows. A data row is one with at least
    one useful cell anywhere, so blank rows Excel keeps below a table do not count."""
    filled = dict.fromkeys(cols, 0)
    rows = 0
    for row in _rows_below(path, sheet, header_row):
        if not any(useful(v) for v in row):
            continue
        rows += 1
        for c in cols:
            if c < len(row) and useful(row[c]):
                filled[c] += 1
    return {c: (filled[c] / rows if rows else 0.0) for c in cols}


def fill_rates(matched: pd.DataFrame, root: Path = ROOT) -> pd.DataFrame:
    """`matched` (from hits()) with fill_rate per column, None where the sheet would not read.

    Every sheet with a match is read to the bottom once. The rates (numbers only, no seller
    values) are cached per file size and modification time, so a rerun reads only files
    that changed."""
    import json

    cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
    cols = matched[["deal_id", "file", "sheet", "header_row", "col"]].drop_duplicates()
    out = []
    for (deal, file, sheet, at), g in cols.groupby(["deal_id", "file", "sheet", "header_row"]):
        path = root / deal / file
        stat = path.stat()
        key = f"{deal}/{file}|{sheet}|{at}|{stat.st_size}|{int(stat.st_mtime)}"
        wanted = sorted(int(c) for c in g.col.unique())
        known = cache.get(key, {})
        if not all(str(c) in known for c in wanted):
            try:
                known = {str(c): r for c, r in _sheet_fill(path, sheet, int(at), wanted).items()}
            except Exception:  # noqa: BLE001 -- read for headers but not for values: say unknown
                known = {str(c): None for c in wanted}
            cache[key] = known
        out += [(deal, file, sheet, at, c, known[str(c)]) for c in wanted]
    CACHE.parent.mkdir(exist_ok=True)
    CACHE.write_text(json.dumps(cache))
    rates = pd.DataFrame(out, columns=["deal_id", "file", "sheet", "header_row", "col", "fill_rate"])
    return matched.merge(rates, on=["deal_id", "file", "sheet", "header_row", "col"], how="left")


def attribute_fill(rated: pd.DataFrame) -> dict[tuple[str, str], float]:
    """(deal, attribute) -> fill rate of its best column. A derived attribute is only as
    filled as its emptiest input, taking the best of its options."""
    q = rated.groupby(["deal_id", "attribute"]).fill_rate.max().to_dict()
    for deal in rated.deal_id.unique():
        for attr, options in DERIVED.items():
            if (deal, attr) in q:
                continue
            rates = [min(q[(deal, n)] for n in needs) for needs in options
                     if all(pd.notna(q.get((deal, n))) for n in needs)]
            if rates:
                q[(deal, attr)] = max(rates)
    return {k: v for k, v in q.items() if not k[1].startswith("_")}
