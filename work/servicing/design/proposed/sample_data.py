"""Illustrative figures for the proposed Cases page, so the mock can be reviewed before the dbt change runs.

Real: the portfolios, their names, servicers, countries and, per month, cases on book, paying cases, first-time payers,
three-months-running payers and euro collected, all from today's PROD cases mart (MART_NPL_SERVICING_AGG_CASES_MONTHLY).
Made up: everything the dbt change adds (open/closed, closed in month, insolvency, phase) and the second-change figures
(Lost after 6 months, steady 6M payers, big payments). The rules below set their rough size from shares measured on
2026-10-15; nothing here may be quoted.
"""
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3]))  # local-workspace/work
import datalake
import numpy as np
import pandas as pd

HERE = pathlib.Path(__file__).parent
rng = np.random.default_rng(15)

m = datalake.q("""
WITH fx AS (
    SELECT quote_currency AS ccy, ultimo_value AS rate FROM PROD.COMMON.FCT_EXCHANGE_RATE_MONTHLY
    WHERE base_currency = 'EUR' AND rate_type = 'PMI' AND date_day = '2026-09-30'
    UNION ALL SELECT 'EUR', 1
),
info AS (
    SELECT s.portfolio_sk, ANY_VALUE(s.country_id) AS country_id, ANY_VALUE(s.currency_id) AS currency_id,
           ANY_VALUE(s.deal_sk) AS deal_sk, ANY_VALUE(rs.servicer_name) AS servicer
    FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY s
    JOIN PROD.NPL_COMMON.DIM_REPORTING_SYSTEM rs ON rs.reporting_system_sk = s.reporting_system_sk
    WHERE s.date_day = '2026-09-30' GROUP BY 1
)
SELECT p.portfolio_sk, p.portfolio_bk, d.deal_alias, i.country_id, i.servicer, LAST_DAY(a.period_end_date) AS m,
       a.cases_on_book_count AS book, a.collected_cases_count AS payers, a.collected_cases_first_collection_count AS new_payers,
       a.collected_cases_three_consecutive_months_count AS three_m, a.collected_cases_lost_count AS lost_3m,
       a.collected_amount_local_sum * fx.rate AS eur
FROM PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY a
JOIN PROD.NPL_COMMON.DIM_PORTFOLIO p ON p.portfolio_sk = a.portfolio_sk
JOIN info i ON i.portfolio_sk = a.portfolio_sk
LEFT JOIN PROD.NPL_COMMON.DIM_DEAL d ON d.deal_sk = i.deal_sk
LEFT JOIN fx ON fx.ccy = i.currency_id
WHERE LAST_DAY(a.period_end_date) BETWEEN '2025-10-31' AND '2026-09-30'
  AND p.capex_date IS NOT NULL AND LAST_DAY(a.period_end_date) >= LAST_DAY(p.capex_date)
  AND a.cases_on_book_count > 0
""", lower=True)
m = m.fillna({'payers': 0, 'new_payers': 0, 'three_m': 0, 'lost_3m': 0, 'eur': 0})
m['servicer'] = m.servicer.str.lower()

# Share of the book closed at month end, by servicer (measured shape, 2026-10-15)
CLOSED = {'intrum': .45, 'gescobro': .03, 'cerved': .87, 'massey': .08, 'souq': 0.0}
# Phase mix of open cases (Amicable, Legal, Enforcement, Not assigned, No phase data), by country for Intrum
PH = {'PT': (0, 0, 0, .02, .98), 'SE': (.06, .02, 0, .9, .02), 'FI': (.05, .15, .35, .45, 0), 'CH': (.35, .07, .03, .55, 0),
      'PL': (.45, .15, .35, .05, 0), 'ES': (.86, .14, 0, 0, 0), 'GR': (.68, .32, 0, 0, 0)}
DEFAULT_PH = (.8, .17, .02, .01, 0)

rows = []
for r in m.itertuples():
    j = lambda x, s=.06: x * (1 + rng.normal(0, s))
    closed_share = min(.98, max(0, j(CLOSED.get(r.servicer, .1), .02)))
    closed = round(r.book * closed_share)
    open_ = r.book - closed
    ph = PH.get(r.country_id, DEFAULT_PH) if r.servicer == 'intrum' else (0, 0, 0, 0, 1)
    ph = np.array(ph) * np.array([j(1, .04) for _ in ph]); ph = ph / ph.sum()
    counts = np.floor(ph * open_).astype(int); counts[np.argmax(ph)] += open_ - counts.sum()
    closed_eur = max(0, j(.012, .3)) * r.eur
    rows.append(dict(portfolio_sk=r.portfolio_sk, portfolio_bk=r.portfolio_bk, deal_alias=r.deal_alias, country_id=r.country_id,
        servicer=r.servicer.title(), m=r.m, book=r.book, open_=open_, closed=closed,
        closed_in_month=round(max(0, j(.0022, .25)) * open_) if r.servicer != 'souq' else 0,
        open_insolvent=round(max(0, j(.027, .2)) * open_) if r.servicer == 'intrum' else 0,
        ph_amicable=counts[0], ph_legal=counts[1], ph_enforcement=counts[2], ph_not_assigned=counts[3], ph_no_data=counts[4],
        payers=r.payers, eur=r.eur, eur_open=r.eur - closed_eur, eur_closed=closed_eur, new_payers=r.new_payers,
        steady_6m=round(max(0, j(.55, .1)) * r.three_m), lost_6m=round(max(0, j(.45, .15)) * r.lost_3m),
        lost_6m_last_eur=r.eur / max(r.payers, 1) * round(max(0, j(.45, .15)) * r.lost_3m) * 1.1))
mo = pd.DataFrame(rows); mo['m'] = pd.to_datetime(mo.m).dt.strftime('%Y-%m-%d')
mo.to_csv(HERE / 'mock_monthly.csv', index=False)

# Big payments, Apr-Sep 2026: share of payers and of euro by bucket, and how many stop afterwards
B = [('0', .70, .22, .25), ('1', .10, .08, .28), ('2', .09, .11, .33), ('5', .05, .12, .40), ('10', .035, .17, .52), ('25', .015, .13, .63), ('50', .01, .17, .74)]
big = []
for r in mo[mo.m >= '2026-04-30'].itertuples():
    for b, sp, se, stop in B:
        n = round(r.payers * max(0, sp * (1 + rng.normal(0, .15))))
        if n == 0: continue
        follow = n if r.m <= '2026-06-30' else 0
        st = round(follow * min(.95, max(0, stop + rng.normal(0, .06))))
        big.append(dict(portfolio_sk=r.portfolio_sk, m=r.m, bucket=b, payers=n, eur=r.eur * se * (1 + rng.normal(0, .15)),
                        stopped_after=st, kept_paying_after=follow - st))
pd.DataFrame(big).to_csv(HERE / 'mock_big.csv', index=False)
print(len(mo), 'portfolio-months', mo.portfolio_sk.nunique(), 'portfolios', len(big), 'big rows')
