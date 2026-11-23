import pandas as pd, numpy as np, sys
Q=sys.argv[1]
pay=pd.read_csv(f"{Q}/b5.csv",parse_dates=["M"]); acc=pd.read_csv(f"{Q}/acc4.csv",parse_dates=["WAREHOUSE_REGISTRATION_DATE","WAREHOUSE_DEFAULT_DATE"])
c=pd.read_csv(f"{Q}/b6.csv",parse_dates=["DEFAULT_DATE"])
pay["A"]=pay.AMT.round(2); pay=pay[pay.A>0]
own=set(acc.MODEL_ID); ai_ids=set(c[c.SRC=="ai"].ID); known=own&ai_ids
own_un=own-ai_ids; ai_un=ai_ids-own
r=pay[(pay.SRC=="raw")][["CASE_BK","M","A"]].rename(columns={"CASE_BK":"owned"})
a=pay[(pay.SRC=="ai")][["CASE_BK","M","A"]].rename(columns={"CASE_BK":"ai"})
def score(aset, oset):
    j=a[a.ai.isin(aset)].merge(r[r.owned.isin(oset)],on=["M","A"])
    s=j.groupby(["ai","owned"]).size().rename("hits").reset_index()
    n_ai=a[a.ai.isin(aset)].groupby("ai").size(); n_own=r[r.owned.isin(oset)].groupby("owned").size()
    s["ai_months"]=s.ai.map(n_ai); s["own_months"]=s.owned.map(n_own)
    return s
def mutual_best(s, min_hits, margin):
    s=s.sort_values("hits",ascending=False)
    top_a=s.groupby("ai").head(2).groupby("ai").hits.apply(list)
    top_o=s.groupby("owned").head(2).groupby("owned").hits.apply(list)
    best_a=s.groupby("ai").head(1).set_index("ai")
    ok=[]
    for ai_id,row in best_a.iterrows():
        h=row.hits; o=row.owned
        if h<min_hits: continue
        la=top_a[ai_id]; lo=top_o[o]
        if len(la)>1 and la[1]*margin>h: continue          # runner-up for this ai too close
        if lo[0]!=h: continue                               # not the owned case's best
        if len(lo)>1 and lo[1]*margin>h: continue
        ok.append((ai_id,o,h,row.ai_months,row.own_months))
    return pd.DataFrame(ok,columns=["ai_case_id","owned_case_bk","equal_months","ai_paying_months","owned_paying_months"])
sk=score(known, own)      # validation: known ai cases searched among ALL owned
print("rule                    | validation on known pairs: matched right wrong precision | new matches")
for mh in (3,5):
    for mg in (2,):
        v=mutual_best(sk,mh,mg)
        right=(v.ai_case_id==v.owned_case_bk).sum(); wrong=len(v)-right
        su=score(ai_un, own_un); new=mutual_best(su,mh,mg)
        print(f">= {mh} equal months, 2x margin | {len(v):5d} {right:5d} {wrong:3d} {right/max(len(v),1)*100:9.3f}% | {len(new)}")
        new.to_csv(f"{Q}/new_matches_h{mh}.csv",index=False)
new=pd.read_csv(f"{Q}/new_matches_h3.csv")
print(new.assign(p=new.ai_case_id.str[:4]+"->"+new.owned_case_bk.str[:4]).p.value_counts().to_dict())
print(new.equal_months.describe()[["min","50%","max"]].to_dict())
# principal / default agreement on new matches as independent check
ai=c[c.SRC=="ai"].set_index("ID"); raw=c[c.SRC=="raw"].set_index("ID"); w=acc.set_index("MODEL_ID")
new["principal_equal"]=[round(ai.PRINCIPAL[x],2)==round(raw.PRINCIPAL.get(y,np.nan),2) for x,y in zip(new.ai_case_id,new.owned_case_bk)]
new["default_equal"]=[ai.DEFAULT_DATE[x]==w.WAREHOUSE_DEFAULT_DATE.get(y) for x,y in zip(new.ai_case_id,new.owned_case_bk)]
new["ai_post_total"]=0
print("independent check on new matches: principal equal",new.principal_equal.sum(),"default date equal",new.default_equal.sum(),"of",len(new))
# same check on validated known pairs for baseline
v=mutual_best(sk,3,2); v=v[v.ai_case_id==v.owned_case_bk]
print("baseline on right known pairs: principal equal",sum(round(ai.PRINCIPAL[x],2)==round(raw.PRINCIPAL.get(x,np.nan),2) for x in v.ai_case_id),"of",len(v))
new.to_csv(f"{Q}/new_matches_h3.csv",index=False)
print("unmatched with payments: ai",a.ai.isin(ai_un).groupby(a.ai).any().sum() if False else a[a.ai.isin(ai_un)].ai.nunique(),"owned",r[r.owned.isin(own_un)].owned.nunique())

print("\n--- wrong validations")
v=mutual_best(sk,3,2); wr=v[v.ai_case_id!=v.owned_case_bk].copy()
true_hits=sk.set_index(["ai","owned"]).hits
wr["true_pair_hits"]=[true_hits.get((x,x),0) for x in wr.ai_case_id]
wr["true_pair_owned"]=[x in own for x in wr.ai_case_id]
print(wr.assign(inst=wr.ai_case_id.str[:4]+"->"+wr.owned_case_bk.str[:4]).inst.value_counts().to_dict())
print(wr[["equal_months","true_pair_hits","ai_paying_months","owned_paying_months"]].describe().loc[["50%","mean","max"]].to_string())
print(wr.head(8).to_string())
# do raw cases share identical payment series? owned-owned duplicates
rr=r.copy(); sig=rr.sort_values("M").groupby("owned").apply(lambda g: tuple(zip(g.M.dt.strftime('%Y%m'),g.A)))
dup=sig[sig.duplicated(keep=False)]
print("owned cases whose whole raw payment series duplicates another owned case:",len(dup))
# date ranges: does the 1062 twin stop paying when the 2080 case starts?
rng=r.groupby("owned").M.agg(["min","max"])
wr["own1062_first"]=wr.owned_case_bk.map(rng["min"]); wr["own1062_last"]=wr.owned_case_bk.map(rng["max"])
wr["own2080_first"]=wr.ai_case_id.map(rng["min"]); wr["own2080_last"]=wr.ai_case_id.map(rng["max"])
reg=acc.set_index("MODEL_ID").WAREHOUSE_REGISTRATION_DATE
wr["reg1062"]=wr.owned_case_bk.map(reg); wr["reg2080"]=wr.ai_case_id.map(reg)
print(wr[["ai_case_id","owned_case_bk","equal_months","true_pair_hits","reg1062","reg2080","own1062_first","own1062_last","own2080_first","own2080_last"]].head(8).to_string())
print("1062 twin last payment month <= 2080 registration month:", (wr.own1062_last<=wr.reg2080.dt.to_period('M').dt.to_timestamp()).sum(),"of",len(wr))
