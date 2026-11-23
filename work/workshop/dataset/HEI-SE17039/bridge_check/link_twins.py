import pandas as pd, numpy as np, sys
exec(open(f"{sys.argv[1]}/bridge2.py").read().split("sk=score(known, own)")[0].replace("Q=sys.argv[1]","Q=sys.argv[1]"))
reg=acc.set_index("MODEL_ID").WAREHOUSE_REGISTRATION_DATE
# 1) Twins: an asset-index 2080 case whose full-history payments match an owned 1062 case (migration May 2024).
a2080=[x for x in ai_ids if x.startswith("2080")]; o1062=[x for x in own if x.startswith("1062")]
st=score(set(a2080), set(o1062))
tw=mutual_best(st,3,2)
rng=r.groupby("owned").M.max()
tw["last_1062"]=tw.owned_case_bk.map(rng); tw["reg_2080"]=tw.ai_case_id.map(reg)
tw["stops_before_2080"]=tw.last_1062<=tw.reg_2080.dt.to_period("M").dt.to_timestamp()
print("2080 cases on the 2024-05-04 registration:", (reg[reg.index.str.startswith("2080")]=="2024-05-04").sum(), "of", reg.index.str.startswith("2080").sum())
print("twins found (2080 asset-index case <-> owned 1062 case):",len(tw),"| 1062 stops before 2080 registration:",tw.stops_before_2080.sum(),
      "| 2080 side owned:", tw.ai_case_id.isin(own).sum(), "| 1062 side in asset index:", tw.owned_case_bk.isin(ai_ids).sum())
print("2080 twin registration dates:", tw.reg_2080.dt.date.value_counts().head(3).to_dict())
tw.to_csv(f"{Q}/twins.csv",index=False)
# 2) What is left unmatched once twins are linked
own_left=own_un-set(tw.owned_case_bk); ai_left=ai_un-set(tw.ai_case_id)
print("owned not in asset index:",len(own_un),"-> after twins",len(own_left), {k:sum(x.startswith(k) for x in own_left) for k in ("1062","2080")})
print("asset index not owned:",len(ai_un),"-> after twins",len(ai_left), {k:sum(x.startswith(k) for x in ai_left) for k in ("1062","2080")})
# 3) Try the leftovers against each other on payments
nm=mutual_best(score(ai_left,own_left),3,2)
print("new payment matches among leftovers:",len(nm)); print(nm.head(10).to_string())
nm.to_csv(f"{Q}/leftover_matches.csv",index=False)
# 4) Do the leftover asset-index cases have post-2024 payments at all, and how much?
al=a[a.ai.isin(ai_left)]
print("leftover asset-index cases with payments:",al.ai.nunique(),"| last payment month range:",al.groupby("ai").M.max().min().date(),al.groupby("ai").M.max().max().date())
ol=r[r.owned.isin(own_left)]
print("leftover owned cases with raw payments:",ol.owned.nunique(),"| last month range:",ol.groupby("owned").M.max().min().date(),ol.groupby("owned").M.max().max().date())
