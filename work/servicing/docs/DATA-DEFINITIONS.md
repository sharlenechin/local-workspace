# Servicing dashboard - data definitions

Every figure, control and grain on the dashboard, in plain English. Generated from `definitions.csv` by `build_definitions.py`: edit the CSV, not this file.

**Computed in** says where the number is made. SQL means the dashboard query, because the figure must stay correct when a viewer filters the page (see `DESIGN.md` §5). Sigma means a calculated column. dbt mart means `PROD.NPL_COMMON.MART_NPL_SERVICING_AGG_CASES_MONTHLY`, unchanged.

## Scope

| Term | Page | Meaning | Formula | Source | Computed in | Watch out |
|---|---|---|---|---|---|---|
| **Portfolios <br>_also: Portfolios reporting_** | Portfolio | Portfolios that sent a servicer report. | `CountDistinct([Portfolio Name])` | `portfolio_name` | Sigma | The book grows month by month (154 in Dec 2025 to 264 in Aug 2026); month-on-month totals are not like-for-like. |
| **Reporting month <br>_also: Month_** | Both | The month the figures describe. One control sets it for every page. | `[Reporting Month]` | `reporting_month` | SQL | Shows only complete months: a month still loading (September 2026: 4 of 264 portfolios) is held back. |
| **Data as of** | Both | The newest month every portfolio has reported. | `Max([Latest Reporting Month])` | `latest_reporting_month` | SQL | About five weeks behind today: servicers report a month after it closes. |
| **Case feed coverage <br>_also: Feed portfolios, Portfolios with a case feed_** | Cases | Portfolios that send a case-level feed. | `CountDistinct(If(not IsNull([Collected Cases]); [Portfolio Name]))` | `have_loan_detail_flag` | SQL (flag) · Sigma (count) | 148 of 264 in August 2026 (146 Intrum, 2 Massey; measured 2026-10-12): only Intrum and Massey portfolios. A blank means no feed — never "nobody paid". |
| **Month still loading <br>_also: Still loading, Loading_** | Both | A newer month only some portfolios have reported. Held back until complete. | `loading_month · loading_month_portfolio_count` | `last_complete_month guard → loading_month_portfolio_count` | SQL | September 2026: 4 of 264 portfolios on 2026-10-09. The header says how many have reported. |

## Collections

| Term | Page | Meaning | Formula | Source | Computed in | Watch out |
|---|---|---|---|---|---|---|
| **Collections <br>_also: Gross collections, Collected, Total collections to date, Collections to date, Collections (portfolios with a servicer forecast), Total collections_** | Portfolio | What debtors paid, before servicer costs, in euro. | `Sum([Collections Sum])` | `FCT_PORTFOLIO_SNAPSHOT_MONTHLY.GROSS_CASH_RECOVERIES → collections_sum` | SQL (euro) · Sigma (sum) | Net of reversals, so a month can be negative (12 portfolio-months on 2026-10-09). Every month converted at the latest month-end rate, as the NPL dashboard (since 2026-10-14). |
| **Net collections <br>_also: Net, Total net collections_** | Portfolio | Collections minus what the servicer keeps. | `Sum([Net Collections Sum])` | `FCT_PORTFOLIO_SNAPSHOT_MONTHLY.NET_CASH_RECOVERIES → net_collections_sum` | SQL (euro) · Sigma (sum) |  |
| **Servicer cost as % of collections <br>_also: Servicer cost, % of gross, Cost % of gross, Servicer cost, Servicer cost, % of collections_** | Portfolio | The servicer's commission, fees and costs, as a share of collections. | `Sum([Servicer Cost Total Sum]) / Sum([Collections Sum])` | `gross minus net → servicer_cost_total_sum` | Sigma | Never average a ratio: sum the cost and the collections first. |

## Benchmark

| Term | Page | Meaning | Formula | Source | Computed in | Watch out |
|---|---|---|---|---|---|---|
| **Servicer forecast <br>_also: vs servicer, Servicer_** | Portfolio | The servicer's own plan for each portfolio. | `Sum(If([Have Servicer Forecast Flag]; [Collections Sum])) / Sum([Servicer Forecast Sum])` | `FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY (latest version) → servicer_forecast_sum` | SQL (latest version · euro) · Sigma (ratio) | Like-for-like: only portfolio-months that have a servicer forecast count. Counting all collections shows 118.9% instead of 105.6%. |
| **Accounting forecast <br>_also: vs accounting, Accounting_** | Portfolio | Finance's current plan; the one the flash report tracks. | `Sum([Collections Sum]) / Sum([Accounting Forecast Sum])` | `FCT_PORTFOLIO_FORECAST_ACCOUNTING_SNAPSHOT_MONTHLY (latest version) → accounting_forecast_sum` | SQL (latest version · euro) · Sigma (ratio) | Covers every portfolio-month. Identical to underwriting in December 2025 — confirm with finance before quoting that month. Revised each vintage. |
| **Underwriting forecast <br>_also: vs underwriting, Underwriting_** | Portfolio | What we expected when we bought. Never revised. | `Sum([Collections Sum]) / Sum([Underwriting Forecast Sum])` | `FCT_PORTFOLIO_FORECAST_UNDERWRITING_SNAPSHOT_MONTHLY (latest version) → underwriting_forecast_sum` | SQL (latest version · euro) · Sigma (ratio) | Starts 2025-06-30: there is no plan before that. |
| **Collections as % of forecast <br>_also: % of forecast, vs forecast, of forecast, % of servicer forecast, % of accounting forecast, % of underwriting forecast, % of forecast (selected benchmark)_** | Portfolio | Collections divided by the chosen forecast. Above 100% is ahead of plan. | `Sum(collections) / Sum(forecast) at the chosen grain` | `—` | Sigma | Sum over sum — never an average of monthly percentages. |
| **Collections minus forecast <br>_also: Gap to forecast, Gap, Gap to servicer, Gap to accounting, Gap to underwriting, Collections minus servicer forecast, Collections minus accounting forecast, Collections minus underwriting forecast_** | Portfolio | Collections less the chosen forecast, in euro. Negative means behind. | `Sum(collections) − Sum(forecast)` | `—` | Sigma |  |
| **Like-for-like** | Portfolio | Only the portfolio-months that have the forecast being compared. | `[Have Servicer Forecast Flag]` | `have_servicer_forecast_flag` | SQL (flag) · Sigma (filter) | Matters only for the servicer forecast; accounting and underwriting cover every portfolio-month. |
| **Forecast (selected benchmark) <br>_also: Forecast, Total forecast_** | Portfolio | The forecast chosen with the Benchmark toggle, over the window. | `Sum of the chosen forecast's window column (e.g. accounting_forecast_l3m_sum)` | `servicer_forecast_* · accounting_forecast_* · underwriting_forecast_*` | SQL (window) · Sigma (switch) | The servicer forecast covers only portfolios that have one; the % and gap tiles compare like-for-like. |

## Windows

| Term | Page | Meaning | Formula | Source | Computed in | Watch out |
|---|---|---|---|---|---|---|
| **This month** | Both | The selected reporting month on its own (§2 Performance and Data Quality windows; the overview cards always show it). | `the month's value` | `—` | Sigma |  |
| **Previous month <br>_also: LM, L1M_** | Both | The month before the latest reporting month. | `[… L 1 M Sum]` | `*_l1m_sum` | SQL | Never includes the selected month. |
| **Last 3 months <br>_also: L3M_** | Both | The three months before the latest reporting month. | `Sum([… L 3 M Sum]) / Max([Months in L 3 M Window])` | `*_l3m_sum · months_in_l3m_window` | SQL (window) · Sigma (average) | In SQL so a date filter cannot change its meaning. Cases divide by months with case data, not months with collections. Averages divide by the months that exist. |
| **Last 6 months <br>_also: L6M_** | Both | The six months before the latest reporting month. | `Sum([… L 6 M Sum]) / Max([Months in L 6 M Window])` | `*_l6m_sum · months_in_l6m_window` | SQL (window) · Sigma (average) |  |
| **Last 12 months <br>_also: L12M_** | Both | The twelve months before the latest reporting month. | `Sum([… L 12 M Sum]) / Max([Months in L 12 M Window])` | `*_l12m_sum · months_in_l12m_window` | SQL (window) · Sigma (average) | Only 8 earlier months exist today, so it uses those. |
| **Comparison window <br>_also: Comparison Window (Average Monthly), Window, Prior period_** | Both | What an overview card's % compares the latest reporting month with: the month before (L1M), or the average month of the 3, 6 or 12 months before it. Ratios compare with the window's ratio. | `latest month ÷ window average − 1 (money); latest ratio − window ratio (points)` | `—` | Sigma | The cards themselves never change with it: only the % does (2026-10-12). |
| **Cumulative** | Portfolio | Running total from each portfolio's first month. | `[Cumulative Collections Sum]` | `cumulative_collections_sum` | SQL |  |

## Data quality

| Term | Page | Meaning | Formula | Source | Computed in | Watch out |
|---|---|---|---|---|---|---|
| **Reconciled <br>_also: Reconciled share, Reconciled %, Reconciled portfolios, Reconciliation, Share of collections reconciled, Share reconciled, Portfolios reconciled, Not reconciled, Collections not reconciled_** | Both | The case feed agrees with the servicer's report. | `Sum(If([Is Reconciled Flag]; [Collections Sum])) / Sum([Collections Sum])` | `is_reconciled_flag` | SQL (flag) · Sigma (share) | 40.3% of collections reconcile (Dec 2025 – Aug 2026, Italy excluded by hand from 2026-10-14). Unreconciled is a data-quality signal, not an error in the dashboard. Amounts within 10% and at least 80% of months present. Italy is marked Not reconciled by hand (2026-10-14): a dbt bug keeps one payment per Italian case, so its case behaviours are wrong even where the euros agree. |
| **Data status** | Both | Why a figure may look odd: reconciliation or a feed gap. | `—` | `is_reconciled_flag · have_loan_detail_flag · feed_stopped_flag` | SQL (flags) · Sigma (wording) | On the Data Quality page, read over that page's Window. 'Reconciled' when 99.5% or more of the portfolio's collections reconcile; otherwise the share of value that does. Reads like: 'Reconciled.', '51% reconciled. Feed 16 of 18.', 'No case feed.', '2 feeds stopped.', 'No data.' (did not report in the window). |
| **No case feed <br>_also: Portfolios with no case feed_** | Both | Portfolios reporting collections in the window that send no case feed, so their collections cannot be reconciled. | `Portfolios reporting − Portfolios with a case feed` | `have_loan_detail_flag` | Sigma | Always tallies: with a case feed + no case feed = portfolios reporting. Cerved, Gescobro and Fire send none yet. |
| **Case feed stopped <br>_also: Feed stopped, Feeds stopped, Case feeds stopped_** | Both | The portfolio's case feed has gone quiet. | `feed_stopped_flag` | `feed_stopped_flag` | SQL | 39 portfolio-months on 2026-10-09. Case figures for these read low because data stopped arriving. |

## Grains

| Term | Page | Meaning | Formula | Source | Computed in | Watch out |
|---|---|---|---|---|---|---|
| **All book <br>_also: Book_** | Both | Every portfolio in scope. | `—` | `—` | Sigma |  |
| **Country** | Both | The portfolio's country. | `[Country Name]` | `country_name` | SQL |  |
| **Servicer** | Portfolio | Servicer group: Intrum, Massey, Fire, Gescobro or Cerved. | `[Servicer Group]` | `servicer_group` | SQL | Derived from deal source and country (the manager's rule, 2026-10-12): ORGANIC ORIGINATED + UK = Massey; ORGANIC ORIGINATED + IT = Fire; ORGANIC ORIGINATED, LEGACY or GESCOBRO + ES = Gescobro; LEGACY + IT = Cerved; everything else Intrum. Fire has no case feed to confirm it. |
| **Vehicle** | Both | The legal entity that owns the portfolio. | `[Vehicle]` | `vehicle` | SQL | Grouped by name: the key splits when Brocc's stake changes. |
| **Seller** | Both | The bank or lender that sold us the debt. | `[Seller]` | `seller` | SQL | Every deal has exactly one seller (49 sellers over 62 deals on 2026-10-09), so Seller sits between Vehicle and Deal. |
| **Deal** | Both | The acquisition the portfolio belongs to. | `[Deal]` | `deal` | SQL |  |
| **Portfolio** | Both | One purchased book of debt. | `[Portfolio Name]` | `portfolio_name` | SQL |  |

## Behaviour

| Term | Page | Meaning | Formula | Source | Computed in | Watch out |
|---|---|---|---|---|---|---|
| **Collected cases <br>_also: Collected case-months, Collected cases count, All collected cases_** | Cases | Cases that paid something in the month. | `Sum([Collected Cases])` | `MART_NPL_SERVICING_AGG_CASES_MONTHLY.collected_cases_count` | dbt mart · Sigma (sum) | A floor, never a total: only Intrum and Massey portfolios send a case feed. Summed over months it counts case-months, not people. |
| **Collected cases, % of book <br>_also: Collected cases % of book, Paying share of book_** | Cases | Of the cases on book, the share that paid something in the month. | `Sum([Collected Cases Count]) / Sum([Cases On Book Count])` | `collected_cases_count / cases_on_book_count` | Sigma | §2: the latest month, against the window's total paid ÷ total on book, change in points. §3: over the selected months, case-months paid ÷ case-months on book. Only months with a case feed count. |
| **New <br>_also: First collection, First-ever payment_** | Cases | A case's first-ever payment. | `Sum([Collected Cases First Collection])` | `collected_cases_first_collection_count` | dbt mart | Never overlaps Fresh: a case's first payment is New, every later return after two quiet months is Fresh. |
| **Three consecutive months <br>_also: Three consecutive_** | Cases | Paid this month and in each of the two before. | `Sum([Collected Cases Consistent 3M])` | `collected_cases_three_consecutive_months_count` | dbt mart | The live column is still called Consistent 3M; the dbt name is used everywhere new. |
| **Jitter in** | Cases | Paid, skipped one month, then paid again. | `Sum([Collected Cases Jitter In])` | `collected_cases_jitter_in_count` | dbt mart |  |
| **Jitter out** | Cases | Paid in one month between two quiet months. | `Sum([Collected Cases Jitter Out Count])` | `collected_cases_jitter_out_count` | dbt mart | January 2026 is inflated: the first month it can be measured. Counted on the quiet month. |
| **Fresh <br>_also: Back after two quiet months, Returning after two quiet months, Fresh (excl. New)_** | Cases | Paid this month after two quiet months, having paid at some point before. Excludes New (2026-10-13). | `Sum([Collected Cases New]) − Sum([Collected Cases First Collection])` | `collected_cases_new_count − collected_cases_first_collection_count` | Sigma | dbt's new counts New and Fresh together; the dashboard takes New out. December 2025 is the first month in the data, so every December payer is New and none is Fresh. |
| **Lost** | Cases | Paid two months running, then nothing. | `Sum([Collected Cases Lost])` | `collected_cases_lost_count` | dbt mart | None can be lost before February 2026. Counted on the first quiet month. On the chart it sits below zero: those cases did not pay this month. |
| **Two of three months** | Cases | Paid this month and in one of the two months before, not both. | `Collected cases − New − Fresh − Three consecutive months` | `collected_cases_count − collected_cases_new_count − collected_cases_three_consecutive_months_count` | SQL (chart source) | Chart only: the group that makes New + Fresh + Two of three months + Three consecutive months add up to collected cases. Its euro is the rest of the month's collections from cases, so it also carries refunds and reversals on cases whose month netted to zero or below (December 2025: −€23k). |
| **Net change in collected cases <br>_also: New plus fresh minus lost, Net gained, Fresh minus lost_** | Cases | New plus fresh, minus lost: is the paying base growing? | `Sum(New) + Sum(Fresh) − Sum(Lost)` | `collected_cases_new_count − collected_cases_lost_count` | Sigma | Not a breakdown of collected cases: the behaviours do not add up to it. |

## Book

| Term | Page | Meaning | Formula | Source | Computed in | Watch out |
|---|---|---|---|---|---|---|
| **Cases on book** | Cases | Cases Brocc owns at the month end. | `Sum(If(selected month; [Cases on Book]))` | `cases_on_book_count` | dbt mart | Never sum across months — that multiplies the book by the month count. A stock: it repeats every month. |
| **Cases ever collected <br>_also: Ever collected_** | Cases | Cases that have paid at least once. | `Sum(If(selected month; [Cases Ever Collected]))` | `cases_ever_collected_count` | dbt mart | Ever means so far, not eventually. |
| **Cases never collected <br>_also: Never collected, Non-paying_** | Cases | Cases that have never paid: the non-paying book. | `Sum(If(selected month; [Cases Never Collected]))` | `cases_never_collected_count` | dbt mart | Ever + never = cases on book on every row (tested). |
| **Cases ever collected, % of book <br>_also: Ever collected, % of book_** | Cases | Share of the book that has ever paid. | `Sum(Cases Ever Collected) / Sum(Cases on Book) at the selected month` | `—` | Sigma | 3.26% in August 2026. |

## Case collections

| Term | Page | Meaning | Formula | Source | Computed in | Watch out |
|---|---|---|---|---|---|---|
| **Collections from collected cases <br>_also: Collected €, Collected cases €, Collected cases EUR, Paid by collected cases_** | Cases | What paying cases paid in the month, in euro. | `Sum([Collected Cases Amount Sum])` | `collected_amount_local_sum → collected_cases_amount_sum` | SQL (euro) · Sigma (sum) | A different feed from portfolio collections: 92.4% of them on the same portfolios, 98.2% where reconciled. Never mix the two on one card. |
| **Average collections per collected case <br>_also: € per collected case, € per case, Collections per collected case, Average monthly collection per case, Avg monthly collection per case_** | Cases | Average euro paid per paying case. | `Sum(Collected €) / Sum(Collected cases)` | `—` | Sigma |  |
| **Avg collection per case, by behaviour <br>_also: Average Collection per Case, Avg Collection per Case_** | Cases | What each behaviour's cases paid per case in the month. | `Sum(behaviour €) / Sum(behaviour cases)` | `—` | Sigma | Lost: per case in their last paying month. All Collected Cases is the month's overall figure. |
| **Collections from new cases <br>_also: New €, First collection €_** | Cases | What first-time payers paid in the month. | `Sum([Collected Cases First Collection Amount Sum])` | `collected_amount_local_first_collection_sum` | SQL (euro) |  |
| **Collections from fresh cases <br>_also: Fresh €_** | Cases | What fresh payers (back after two quiet months, having paid before) paid in the month. | `Sum([Collected Cases New Amount Sum]) − Sum([Collected Cases First Collection Amount Sum])` | `collected_amount_local_new_sum − collected_amount_local_first_collection_sum` | SQL (euro) |  |
| **Collections from three-consecutive-month cases <br>_also: Three consecutive months €_** | Cases | What steady payers paid in the month. | `Sum([Collected Cases Three Consecutive Months Amount Sum])` | `collected_amount_local_three_consecutive_months_sum` | SQL (euro) |  |
| **Collections from jitter-in cases <br>_also: Jitter in €_** | Cases | What returning payers paid in the month. | `Sum([Collected Cases Jitter In Amount Sum])` | `collected_amount_local_jitter_in_sum` | SQL (euro) |  |
| **Lost cases: collections in their last paying month <br>_also: Lost, last-month €_** | Cases | What lost cases paid in their last paying month. | `Sum([Collected Cases Lost Last Month Amount Sum])` | `collected_amount_local_lost_last_month_sum` | SQL (euro) | Belongs to an earlier month than the one it is reported in. |
| **Jitter-out cases: collections in their last paying month <br>_also: Jitter out, last-month €_** | Cases | What jitter-out cases paid in their one paying month. | `Sum([Collected Cases Jitter Out Last Month Amount Sum])` | `collected_amount_local_jitter_out_last_month_sum` | SQL (euro) | Belongs to an earlier month than the one it is reported in. |
