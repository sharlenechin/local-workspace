"""Real figures for the proposed Cases page mock (the dashboard as it would read once the sc/servicing-dashboard dbt
PR is live). Read-only against PROD and RAW; writes mock_data.json beside this file.

Scope matches the live dashboard: owned portfolio-months only (capex month onward), Oct 2025 - Sep 2026,
euro at each currency's month-end rate for the latest complete month (Sep 2026), as the dashboard converts.
The seed is inlined as VALUES because it is not in PROD yet; the phase periods are rebuilt from RAW the way
int_npl_case_phase_intrum builds them.
"""
import json, pathlib, sys, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3]))  # local-workspace/work
import datalake
import pandas as pd

HERE = pathlib.Path(__file__).parent
SEED = pathlib.Path(__file__).resolve().parents[2] / 'dbt/seeds/npl_status_code_mappings.csv'
s = pd.read_csv(SEED, dtype=str, keep_default_na=False)
VALS = ",\n".join(f"('{r.servicer_name}','{r.status_code}',{r.is_closed_status_flag.upper()},{r.is_insolvent_status_flag.upper()})" for r in s.itertuples())
P = 'data-prod-data-raw-sftp-071269be/intrum/cat.'

COMMON = f"""
WITH months AS (
    SELECT date_day AS m FROM PROD.COMMON.DIM_DATE WHERE is_month_end AND date_day BETWEEN '2025-10-31' AND '2026-09-30'
),
seed (servicer_name, status_code, is_closed_status_flag, is_insolvent_status_flag) AS (SELECT * FROM VALUES {VALS}),
fx AS (
    SELECT quote_currency AS ccy, ultimo_value AS rate FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    WHERE base_currency = 'EUR' AND rate_type = 'PMI' AND date_day = '2026-09-30'
    UNION ALL SELECT 'EUR', 1
),
owned AS (
    SELECT portfolio_sk, portfolio_bk, LAST_DAY(capex_date) AS capex_month_end FROM PROD.NPL_COMMON.DIM_PORTFOLIO WHERE capex_date IS NOT NULL
),
phases AS (
    SELECT case_bk, collection_phase, valid_from,
           COALESCE(LEAD(valid_from) OVER (PARTITION BY case_bk ORDER BY valid_from), '9999-12-31'::DATE) AS valid_to
    FROM (
        SELECT PARSE_JSON(_file_metadata):system::STRING || '-' || case_id AS case_bk, start_date::DATE AS valid_from,
               CASE WHEN group_phase_code = 'NA' THEN 'Not assigned' WHEN LEFT(group_phase_code, 1) = 'A' THEN 'Amicable'
                    WHEN LEFT(group_phase_code, 1) = 'L' THEN 'Legal' WHEN LEFT(group_phase_code, 1) = 'E' THEN 'Enforcement'
                    ELSE 'Not assigned' END AS collection_phase
        FROM RAW.HYPERION_INTRUM_CAT.GROUP_CASE_PHASE
        WHERE _file_path LIKE '{P}%' AND COALESCE(deleted, 0) = 0 AND COALESCE(archived, 0) = 0 AND COALESCE(unlinked, 0) = 0
          AND group_phase_code IS NOT NULL AND start_date::DATE BETWEEN '1950-01-01' AND CURRENT_DATE()
        QUALIFY ROW_NUMBER() OVER (PARTITION BY case_bk, valid_from ORDER BY COALESCE(update_ts, record_update) DESC NULLS LAST, _file_path DESC) = 1
    )
),
states AS (   -- every case on an owned book at each month end, with the PR's three answers
    SELECT s.case_id, s.portfolio_sk, s.date_day AS m, s.outstanding_principal, s.currency_id,
           COALESCE(c.closing_date > s.date_day, TRUE) AND NOT COALESCE(sd.is_closed_status_flag, FALSE) AS is_open,
           COALESCE(DATE_TRUNC('MONTH', c.closing_date) = DATE_TRUNC('MONTH', s.date_day)
               OR (c.closing_date IS NULL AND sd.is_closed_status_flag AND c.effective_from_date > LAST_DAY(DATEADD('MONTH', -1, s.date_day))), FALSE) AS closed_in_month,
           COALESCE(sd.is_insolvent_status_flag, FALSE) AS insolvent,
           COALESCE(p.collection_phase, 'No phase data') AS phase
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY s
    JOIN owned o ON o.portfolio_sk = s.portfolio_sk AND s.date_day >= o.capex_month_end
    JOIN PROD.NPL_COMMON.DIM_CASE c ON c.case_sk = s.case_sk
    LEFT JOIN PROD.NPL_COMMON.DIM_REPORTING_SYSTEM rs ON rs.reporting_system_sk = s.reporting_system_sk
    LEFT JOIN seed sd ON sd.servicer_name = rs.servicer_name AND sd.status_code = TRIM(c.status_code)
    LEFT JOIN phases p ON p.case_bk = c.case_bk AND rs.servicer_name = 'intrum' AND s.date_day >= p.valid_from AND s.date_day < p.valid_to
    WHERE s.date_day BETWEEN '2025-09-30' AND '2026-09-30'
),
case_months AS (   -- what each case collected per month, all history (first-ever and streaks need it)
    SELECT c.case_id, c.portfolio_sk, LAST_DAY(c.collection_date) AS m, SUM(c.amount * fx.rate) AS eur
    FROM PROD.NPL_COMMON.FCT_CASE_COLLECTION c
    JOIN fx ON fx.ccy = c.currency_id
    WHERE c.collection_date < '2026-10-01'
    GROUP BY 1, 2, 3
),
paid AS (   -- net-positive months only, with the length of the unbroken monthly run ending in each
    SELECT case_id, portfolio_sk, m, eur,
           MIN(m) OVER (PARTITION BY case_id) AS first_paid_month,
           ROW_NUMBER() OVER (PARTITION BY case_id, grp ORDER BY m) AS run_len
    FROM (
        SELECT *, DATEDIFF('MONTH', '2000-01-31', m) - ROW_NUMBER() OVER (PARTITION BY case_id ORDER BY m) AS grp
        FROM case_months WHERE eur > 0
    )
)
"""

QUERIES = {
    # One row per portfolio and month: the PR's mart columns plus payer behaviour and euro split by open/closed.
    'monthly': COMMON + """
, book AS (
    SELECT portfolio_sk, m, COUNT(*) AS book, COUNT_IF(is_open) AS open_, COUNT_IF(NOT is_open) AS closed,
           COUNT_IF(NOT is_open AND closed_in_month) AS closed_in_month, COUNT_IF(is_open AND insolvent) AS open_insolvent,
           COUNT_IF(is_open AND phase = 'Amicable') AS ph_amicable, COUNT_IF(is_open AND phase = 'Legal') AS ph_legal,
           COUNT_IF(is_open AND phase = 'Enforcement') AS ph_enforcement, COUNT_IF(is_open AND phase = 'Not assigned') AS ph_not_assigned,
           COUNT_IF(is_open AND phase = 'No phase data') AS ph_no_data
    FROM states WHERE m >= '2025-10-31' GROUP BY 1, 2
),
pay AS (
    SELECT p.portfolio_sk, p.m, COUNT(*) AS payers, SUM(p.eur) AS eur,
           SUM(IFF(COALESCE(st.is_open, TRUE), p.eur, 0)) AS eur_open, SUM(IFF(COALESCE(st.is_open, TRUE), 0, p.eur)) AS eur_closed,
           COUNT_IF(p.m = p.first_paid_month) AS new_payers,
           COUNT_IF(p.run_len >= 7) AS steady_6m
    FROM paid p LEFT JOIN states st ON st.case_id = p.case_id AND st.m = p.m
    WHERE p.m BETWEEN '2025-10-31' AND '2026-09-30' GROUP BY 1, 2
),
lost AS (   -- paid six months running, then nothing: counted on the first quiet month
    SELECT p.portfolio_sk, LAST_DAY(DATEADD('MONTH', 1, p.m)) AS m, COUNT(*) AS lost_6m, SUM(p.eur) AS lost_6m_last_eur
    FROM paid p
    LEFT JOIN paid nxt ON nxt.case_id = p.case_id AND nxt.m = LAST_DAY(DATEADD('MONTH', 1, p.m))
    WHERE p.run_len >= 6 AND nxt.case_id IS NULL AND p.m BETWEEN '2025-09-30' AND '2026-08-31'
    GROUP BY 1, 2
)
SELECT o.portfolio_bk, d.deal_alias, s.country_id, b.*, pay.payers, pay.eur, pay.eur_open, pay.eur_closed, pay.new_payers, pay.steady_6m,
       lost.lost_6m, lost.lost_6m_last_eur
FROM book b
JOIN owned o ON o.portfolio_sk = b.portfolio_sk
LEFT JOIN (SELECT portfolio_sk, ANY_VALUE(country_id) AS country_id, ANY_VALUE(deal_sk) AS deal_sk FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY WHERE date_day = '2026-09-30' GROUP BY 1) s ON s.portfolio_sk = b.portfolio_sk
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL d ON d.deal_sk = s.deal_sk
LEFT JOIN pay ON pay.portfolio_sk = b.portfolio_sk AND pay.m = b.m
LEFT JOIN lost ON lost.portfolio_sk = b.portfolio_sk AND lost.m = b.m
""",
    # Payments as a share of the principal still owed at the previous month end, Apr-Sep 2026, bucketed so a
    # slider can sum the buckets at or above any threshold; and what each big payer did in the next three months.
    'big': COMMON + """
, ratio AS (
    SELECT p.portfolio_sk, p.m, p.case_id, p.eur, p.eur / NULLIF(prev.outstanding_principal * fx_p.rate, 0) AS share
    FROM paid p
    JOIN states prev ON prev.case_id = p.case_id AND prev.m = LAST_DAY(DATEADD('MONTH', -1, p.m))
    JOIN fx fx_p ON fx_p.ccy = prev.currency_id
    WHERE p.m BETWEEN '2026-04-30' AND '2026-09-30'
),
after AS (
    SELECT r.portfolio_sk, r.m, r.case_id, r.eur, r.share, COUNT(q.case_id) AS paid_after
    FROM ratio r
    LEFT JOIN paid q ON q.case_id = r.case_id AND q.m > r.m AND q.m <= LAST_DAY(DATEADD('MONTH', 3, r.m))
    GROUP BY 1, 2, 3, 4, 5
)
SELECT portfolio_sk, m,
       CASE WHEN share IS NULL THEN 'none' WHEN share < 0.01 THEN '0' WHEN share < 0.02 THEN '1' WHEN share < 0.05 THEN '2'
            WHEN share < 0.10 THEN '5' WHEN share < 0.25 THEN '10' WHEN share < 0.50 THEN '25' ELSE '50' END AS bucket,
       COUNT(*) AS payers, SUM(eur) AS eur,
       COUNT_IF(m <= '2026-06-30' AND paid_after = 0) AS stopped_after, COUNT_IF(m <= '2026-06-30' AND paid_after > 0) AS kept_paying_after
FROM after GROUP BY 1, 2, 3
""",
}

if __name__ == '__main__':
    out = {}
    for name in sys.argv[1:] or QUERIES:
        t = time.time()
        df = datalake.q(QUERIES[name], lower=True)
        print(name, len(df), f"{time.time() - t:.0f}s", flush=True)
        df.to_csv(HERE / f"mock_{name}.csv", index=False)
