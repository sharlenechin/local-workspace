import os, pandas as pd, datalake as d
W='work/asset-index-sharepoint'
df=d.q(f'{W}/checks/pam_overlay.sql', connection='sandbox', warehouse='DEV_WH', lower=True)
print(len(df)); print(df.cc.value_counts().to_string()); print('dup deals', df.deal.duplicated().sum())
folders=sorted(x for x in os.listdir(f'{W}/sorted') if '-' in x and not x.startswith('_'))
fmap={x.split('-',1)[1]:x for x in folders}
df['in_pam']=True
df['in_warehouse']=df.vehicle!='(not held)'
extra=[]
for deal,fold in fmap.items():
    if deal not in set(df.deal):
        extra.append(dict(cc=deal[:2],vehicle=fold.split('-')[0],deal_id=fold,deal=deal,seller='(not in PAM)',in_pam=False))
if extra:
    ids=", ".join(f"'{e['deal']}'" for e in extra)
    held=d.q(f"""SELECT servicer_parent_portfolio_bk AS deal FROM PROD_NPL_COMMON.NPL_COMMON.DIM_BATCH WHERE servicer_parent_portfolio_bk IN ({ids})
                UNION SELECT SUBSTR(portfolio_bk,5,7) FROM PROD_NPL_COMMON.NPL_COMMON.DIM_PORTFOLIO WHERE SUBSTR(portfolio_bk,5,7) IN ({ids})""",
             connection='sandbox', warehouse='DEV_WH', lower=True)
    for e in extra: e['in_warehouse']=e['deal'] in set(held.deal)
    df=pd.concat([df,pd.DataFrame(extra)],ignore_index=True)
# In Asset Index = we have the files (a sorted/ folder) AND we own the deal (in the warehouse).
# asset_index_folder still shows the folder for deals we have files for but do not own.
df['in_asset_index']=df.deal.isin(fmap) & df.in_warehouse.astype(bool)
df['asset_index_folder']=df.deal.map(fmap)
names=dict(SE='Sweden',PT='Portugal',FI='Finland',GE='Germany',NO='Norway',DK='Denmark',NL='Netherlands',BE='Belgium',
  IT='Italy',ES='Spain',FR='France',CH='Switzerland',PL='Poland',UK='United Kingdom',GB='United Kingdom',AT='Austria',
  CZ='Czech Republic',SK='Slovakia',HU='Hungary',GR='Greece',IE='Ireland',EE='Estonia',LV='Latvia',LT='Lithuania',
  RO='Romania',BG='Bulgaria',HR='Croatia',SI='Slovenia',RS='Serbia',LU='Luxembourg',DE='Germany')
df['country']=df.cc.map(names)
print('unmapped cc:', sorted(df.loc[df.country.isna(),'cc'].unique()))
df['country']=df.country.fillna(df.cc)
# Same order as pam_overlay_relevant.csv: PAM deals by country code then size,
# asset-index-only deals appended at the end.
df=pd.concat([df[df.in_pam].sort_values(['cc','acq_principal'],ascending=[True,False]),df[~df.in_pam]],ignore_index=True)
print(df[['in_pam','in_warehouse','in_asset_index']].value_counts().to_string())
print(df[~df.in_pam][['deal_id','in_warehouse']].to_string())
df.to_csv(f'{W}/checks/pam_overlay_all.csv',index=False)
with pd.ExcelWriter(f'{W}/checks/pam_overlay_all.xlsx') as xw:
    df.to_excel(xw,sheet_name='pam_overlay_all',index=False)
