-- Collection behaviour of each portfolio's cases, aggregated to one row per
-- portfolio per month. A case counts as collecting where its month nets above zero.
with portfolios_in_scope as (
    select
        portfolio_sk,
        capex_date
    from {{ ref('dim_npl_portfolio') }}
),

-- Every collection row in scope: owned portfolios, from the capex month onward.
case_base as (
    select
        collections.portfolio_sk,
        collections.case_id,
        collections.amount as collected_amount_local,
        date_trunc('MONTH', collections.collection_date) as collection_month
    from {{ ref('fct_npl_case_collection') }} as collections
    inner join portfolios_in_scope as scope
        on collections.portfolio_sk = scope.portfolio_sk
    where
        collections.collection_date < date_trunc('MONTH', current_date())
        and (
            scope.capex_date is null
            or collections.collection_date >= date_trunc('MONTH', scope.capex_date)
        )
),

-- One row per case per month, with what that case collected in it.
case_monthly_collections as (
    select
        portfolio_sk,
        case_id,
        collection_month,
        sum(collected_amount_local) as case_collected_amount_local
    from case_base
    group by
        portfolio_sk,
        case_id,
        collection_month
),

-- The amounts collected either side, which behaviour is classified against.
-- Months are month-start and frames are intervals; a number would count days.
case_monthly_lagged_historical_collections as (
    select
        portfolio_sk,
        case_id,
        collection_month,
        case_collected_amount_local,
        dateadd('MONTH', 1, collection_month) as one_month_after,
        coalesce(sum(case_collected_amount_local) over (
            partition by portfolio_sk, case_id order by collection_month
            range between interval '1 month' preceding and interval '1 month' preceding
        ), 0) as amount_previous_1_month,
        coalesce(sum(case_collected_amount_local) over (
            partition by portfolio_sk, case_id order by collection_month
            range between interval '2 months' preceding and interval '2 months' preceding
        ), 0) as amount_previous_2_months,
        coalesce(sum(case_collected_amount_local) over (
            partition by portfolio_sk, case_id order by collection_month
            range between interval '1 month' following and interval '1 month' following
        ), 0) as amount_next_1_month,
        coalesce(count_if(case_collected_amount_local > 0) over (
            partition by portfolio_sk, case_id order by collection_month
            range between unbounded preceding and interval '1 day' preceding
        ), 0) as collecting_months_before_this_one,
        max(collection_month) over () as latest_collection_month_overall
    from case_monthly_collections
),

-- What each case did that month, over the three months x-2, x-1 and x:
--
--   first_collection             -      -     yes   no prior collection
--   three_consecutive_months    yes    yes    yes
--   jitter_in                   yes     no    yes   returns after one month absent
--   new                          no     no    yes   returns after a longer absence
--   jitter_out                   no    yes     no   a single month, then absent
--   lost                        yes    yes     no   consecutive collection ceases
--
-- The last two fall in a month without a collection, for which no row exists.
-- The second branch derives that row from the case's final collecting month.
case_monthly_collection_behaviour as (
    select
        portfolio_sk,
        collection_month as period_end_date,
        case_collected_amount_local,
        null::number as amount_at_last_collection,
        iff(case_collected_amount_local > 0, 1, 0) as collected_flag,
        iff(
            case_collected_amount_local > 0
            and collecting_months_before_this_one = 0, 1, 0
        ) as first_collection_flag,
        iff(
            case_collected_amount_local > 0
            and amount_previous_1_month > 0
            and amount_previous_2_months > 0, 1, 0
        ) as three_consecutive_months_flag,
        iff(
            case_collected_amount_local > 0
            and amount_previous_1_month <= 0
            and amount_previous_2_months > 0, 1, 0
        ) as jitter_in_flag,
        iff(
            case_collected_amount_local > 0
            and amount_previous_1_month <= 0
            and amount_previous_2_months <= 0, 1, 0
        ) as new_collection_flag,
        0 as jitter_out_flag,
        0 as lost_flag
    from case_monthly_lagged_historical_collections

    union all

    select
        portfolio_sk,
        one_month_after as period_end_date,
        null::number as case_collected_amount_local,
        case_collected_amount_local as amount_at_last_collection,
        0 as collected_flag,
        0 as first_collection_flag,
        0 as three_consecutive_months_flag,
        0 as jitter_in_flag,
        0 as new_collection_flag,
        iff(amount_previous_1_month > 0, 0, 1) as jitter_out_flag,
        iff(amount_previous_1_month > 0, 1, 0) as lost_flag
    from case_monthly_lagged_historical_collections
    where
        case_collected_amount_local > 0
        and amount_next_1_month <= 0
        and one_month_after <= latest_collection_month_overall
),

-- The month each case first collected, for the as-at-month counts below.
case_first_collection as (
    select
        portfolio_sk,
        case_id,
        min(collection_month) as first_collection_month
    from case_monthly_collections
    where case_collected_amount_local > 0
    group by
        portfolio_sk,
        case_id
),

-- The book as at each month end, and how much of it had collected by that point.
-- These three counts are as at the month in question, not as at the current date.
cases_on_book_by_month as (
    select
        snapshot.portfolio_sk,
        date_trunc('MONTH', snapshot.date_day) as period_end_date,
        count(*) as cases_on_book_count,
        count_if(first_collection.first_collection_month <= snapshot.date_day)
            as cases_ever_collected_count,
        count(*) - count_if(first_collection.first_collection_month <= snapshot.date_day)
            as cases_never_collected_count
    from {{ ref('fct_npl_case_snapshot_daily') }} as snapshot
    inner join portfolios_in_scope as scope
        on snapshot.portfolio_sk = scope.portfolio_sk
    left join case_first_collection as first_collection
        on
            snapshot.portfolio_sk = first_collection.portfolio_sk
            and snapshot.case_id = first_collection.case_id
    where
        snapshot.date_day < date_trunc('MONTH', current_date())
        and (
            scope.capex_date is null
            or snapshot.date_day >= date_trunc('MONTH', scope.capex_date)
        )
    group by
        snapshot.portfolio_sk,
        date_trunc('MONTH', snapshot.date_day)
)

select
    behaviour.portfolio_sk,
    last_day(behaviour.period_end_date) as period_end_date,

    sum(behaviour.collected_flag) as collected_cases_count,
    sum(behaviour.first_collection_flag) as collected_cases_first_collection_count,
    sum(behaviour.three_consecutive_months_flag) as collected_cases_three_consecutive_months_count,
    sum(behaviour.jitter_in_flag) as collected_cases_jitter_in_count,
    sum(behaviour.jitter_out_flag) as collected_cases_jitter_out_count,
    sum(behaviour.new_collection_flag) as collected_cases_new_count,
    sum(behaviour.lost_flag) as collected_cases_lost_count,

    coalesce(sum(behaviour.case_collected_amount_local), 0) as collected_amount_local_sum,
    sum(iff(behaviour.first_collection_flag = 1, behaviour.case_collected_amount_local, 0))
        as collected_amount_local_first_collection_sum,
    sum(iff(behaviour.three_consecutive_months_flag = 1, behaviour.case_collected_amount_local, 0))
        as collected_amount_local_three_consecutive_months_sum,
    sum(iff(behaviour.jitter_in_flag = 1, behaviour.case_collected_amount_local, 0))
        as collected_amount_local_jitter_in_sum,
    sum(iff(behaviour.new_collection_flag = 1, behaviour.case_collected_amount_local, 0))
        as collected_amount_local_new_sum,
    sum(iff(behaviour.jitter_out_flag = 1, behaviour.amount_at_last_collection, 0))
        as collected_amount_local_jitter_out_last_month_sum,
    sum(iff(behaviour.lost_flag = 1, behaviour.amount_at_last_collection, 0))
        as collected_amount_local_lost_last_month_sum,

    any_value(book.cases_on_book_count) as cases_on_book_count,
    any_value(book.cases_ever_collected_count) as cases_ever_collected_count,
    any_value(book.cases_never_collected_count) as cases_never_collected_count
from case_monthly_collection_behaviour as behaviour
left join cases_on_book_by_month as book
    on
        behaviour.portfolio_sk = book.portfolio_sk
        and behaviour.period_end_date = book.period_end_date
group by
    behaviour.portfolio_sk,
    behaviour.period_end_date
