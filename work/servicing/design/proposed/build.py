"""Fill template.html with the figures mock_data.py pulled, writing proposed-servicing-dashboard.html.

Portfolio name is the readable label the stakeholder asked for: deal · country · segment, with the portfolio id kept
underneath. Servicer is the case feed's servicer.
"""
import json, pathlib, re, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3]))  # local-workspace/work
import datalake
import pandas as pd

HERE = pathlib.Path(__file__).parent
COUNTRY = {'AT': 'Austria', 'BE': 'Belgium', 'CH': 'Switzerland', 'DE': 'Germany', 'DK': 'Denmark', 'ES': 'Spain', 'FI': 'Finland',
           'FR': 'France', 'GB': 'United Kingdom', 'UK': 'United Kingdom', 'GR': 'Greece', 'IT': 'Italy', 'NL': 'Netherlands',
           'NO': 'Norway', 'PL': 'Poland', 'PT': 'Portugal', 'SE': 'Sweden', 'CY': 'Cyprus', 'IE': 'Ireland', 'CZ': 'Czechia'}

m = pd.read_csv(HERE / 'mock_monthly.csv')
b = pd.read_csv(HERE / 'mock_big.csv', dtype={'bucket': str})
if 'servicer' not in m:   # sample_data.py already carries it
    srv = datalake.q("""SELECT s.portfolio_sk, INITCAP(ANY_VALUE(rs.servicer_name)) AS servicer
        FROM PROD.NPL_COMMON.FCT_CASE_SNAPSHOT_DAILY s JOIN PROD.NPL_COMMON.DIM_REPORTING_SYSTEM rs ON rs.reporting_system_sk = s.reporting_system_sk
        WHERE s.date_day = '2026-09-30' GROUP BY 1""", lower=True)
    m = m.merge(srv, on='portfolio_sk', how='left')
m['country'] = m.country_id.map(COUNTRY).fillna(m.country_id)
seg = m.portfolio_bk.str.extract(r'-([A-Z]\d{2})/')[0]
m['name'] = m.deal_alias.fillna('Unknown deal') + ' · ' + m.country + ' · ' + seg.fillna('')
m['m'] = pd.to_datetime(m.m).dt.strftime('%Y-%m-%d')
num = [c for c in m.columns if c not in ('portfolio_bk', 'deal_alias', 'country_id', 'country', 'servicer', 'name', 'm')]
m[num] = m[num].fillna(0)

info = m.drop_duplicates('portfolio_sk').set_index('portfolio_sk')[['name', 'portfolio_bk', 'country', 'servicer']]
b = b.join(info, on='portfolio_sk', how='inner')
b[['payers', 'eur', 'stopped_after', 'kept_paying_after']] = b[['payers', 'eur', 'stopped_after', 'kept_paying_after']].fillna(0)

keep = ['portfolio_sk', 'portfolio_bk', 'name', 'country', 'servicer', 'm'] + [c for c in num if c != 'portfolio_sk']
data = {'months': sorted(m.m.unique().tolist()),
        'rows': json.loads(m[keep].to_json(orient='records')),
        'big': json.loads(b[['portfolio_sk', 'portfolio_bk', 'name', 'country', 'servicer', 'bucket', 'payers', 'eur', 'stopped_after', 'kept_paying_after']].to_json(orient='records'))}
html = (HERE / 'template.html').read_text().replace('__DATA__', json.dumps(data, separators=(',', ':')))
(HERE / 'proposed-servicing-dashboard.html').write_text(html)
print(len(data['rows']), 'rows', len(data['big']), 'big rows', round(len(html) / 1024), 'KB')
