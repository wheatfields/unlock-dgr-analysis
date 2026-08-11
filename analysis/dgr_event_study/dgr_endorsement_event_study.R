# DGR endorsement event study --------------------------------------------------
#
# Question: does the donations-and-bequests share of revenue change after a
# charity becomes DGR endorsed? Pseudo-counterfactual: compare each switcher's
# own pre- vs post-endorsement years (event-time alignment).
#
# Data:
#   data/analytical/charity_financials_panel.parquet  (abn x ais_year, 2021-24)
#   data/analytical/charity_master.parquet            (dgr_endorsed_from etc.)
#
# Design decisions (agreed 2026-07-24):
#   - Day-level dgr_endorsed_from is rounded to the AIS financial year.
#     For a 30-Jun year end, endorsement in [Jul Y-1, Jun Y] => endorsement_fy = Y.
#     Non-June reporters are handled via financial_year_end (month rollover).
#   - The endorsement FY itself is partial exposure: event_year 0, reported
#     separately; first clean post year is event_year +1.
#   - Ancillary funds (Item 2 / name-match) are excluded.
#   - Charities registered within 1 year of endorsement are flagged as
#     "start-up" (their pre-period reflects establishment, not counterfactual).
#
# Outputs (written next to this script):
#   cohort_gate.csv        — switcher counts by endorsement FY and flags
#   event_time_summary.csv — donation share by event year
#   switcher_panel.csv     — charity-year rows for the switcher cohort
#   event_time_plot.png    — mean/median share by event year

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(lubridate)
  library(arrow)
})

root    <- here::here()
out_dir <- file.path(root, "analysis", "dgr_event_study")

panel  <- read_parquet(file.path(root, "data/analytical/charity_financials_panel.parquet"))
master <- read_parquet(file.path(root, "data/analytical/charity_master.parquet"))

# ---- 1. Endorsement financial year -------------------------------------------

# financial_year_end is like "30-Jun"; extract the month. An endorsement dated
# after the FY-end month belongs to the *next* AIS year.
fy_end_month <- function(fy_end) {
  m <- match(sub("^\\d+-", "", fy_end), month.abb)
  coalesce(m, 6L)  # default 30-Jun
}

master_ev <- master |>
  filter(!is.na(dgr_endorsed_from)) |>
  mutate(
    fy_end_m       = fy_end_month(financial_year_end),
    endorsement_fy = year(dgr_endorsed_from) +
                       as.integer(month(dgr_endorsed_from) > fy_end_m),
    registration_date = dmy(registration_date),
    is_startup = !is.na(registration_date) &
      abs(as.numeric(dgr_endorsed_from - registration_date)) <= 365,
    exclude_ancillary = coalesce(is_ancillary, is_ancillary_provisional, FALSE) |
      coalesce(dgr_item_number == 2L, FALSE)
  ) |>
  select(abn, charity_legal_name, charity_size, dgr_endorsed_from,
         endorsement_fy, is_startup, exclude_ancillary)

# ---- 2. Join panel, define outcome -------------------------------------------

MIN_INCOME <- 1000  # drop near-zero denominators

df <- panel |>
  inner_join(master_ev, by = "abn") |>
  mutate(
    valid_share = !is.na(total_gross_income) & total_gross_income >= MIN_INCOME &
      !is.na(donations_and_bequests) & donations_and_bequests >= 0,
    donation_share = if_else(
      valid_share,
      pmin(donations_and_bequests / total_gross_income, 1),
      NA_real_
    ),
    event_year = ais_year - endorsement_fy
  )

# ---- 3. Cohort gate -----------------------------------------------------------

# Switcher = >=1 valid pre year (event_year < 0) and >=1 valid clean post year
# (event_year >= 1) within the panel window.
switcher_flags <- df |>
  filter(!is.na(donation_share)) |>
  group_by(abn) |>
  summarise(
    n_pre  = sum(event_year < 0),
    n_post = sum(event_year >= 1),
    .groups = "drop"
  ) |>
  filter(n_pre >= 1, n_post >= 1)

gate <- master_ev |>
  semi_join(switcher_flags, by = "abn") |>
  count(endorsement_fy, exclude_ancillary, is_startup, name = "n_switchers") |>
  arrange(endorsement_fy)

write.csv(gate, file.path(out_dir, "cohort_gate.csv"), row.names = FALSE)

n_total   <- sum(gate$n_switchers)
n_usable  <- sum(gate$n_switchers[!gate$exclude_ancillary])
n_clean   <- sum(gate$n_switchers[!gate$exclude_ancillary & !gate$is_startup])
message(sprintf(
  "Cohort gate: %d switchers total; %d after excluding ancillary funds; %d also excluding start-ups",
  n_total, n_usable, n_clean
))
print(gate)

# ---- 4. Event-time analysis (non-ancillary switchers) -------------------------

switchers <- df |>
  semi_join(switcher_flags, by = "abn") |>
  filter(!exclude_ancillary, !is.na(donation_share))

write.csv(switchers |>
            select(abn, charity_legal_name, charity_size, ais_year,
                   endorsement_fy, event_year, is_startup,
                   donations_and_bequests, total_gross_income, donation_share),
          file.path(out_dir, "switcher_panel.csv"), row.names = FALSE)

event_summary <- switchers |>
  group_by(is_startup, event_year) |>
  summarise(
    n            = n(),
    mean_share   = mean(donation_share),
    median_share = median(donation_share),
    .groups = "drop"
  ) |>
  arrange(is_startup, event_year)

write.csv(event_summary, file.path(out_dir, "event_time_summary.csv"),
          row.names = FALSE)
print(event_summary, n = Inf)

# Within-charity change: mean post (>= +1) minus mean pre (< 0)
within_change <- switchers |>
  group_by(abn, is_startup) |>
  summarise(
    pre  = mean(donation_share[event_year < 0]),
    post = mean(donation_share[event_year >= 1]),
    .groups = "drop"
  ) |>
  filter(!is.na(pre), !is.na(post)) |>
  mutate(change = post - pre)

change_summary <- within_change |>
  group_by(is_startup) |>
  summarise(
    n             = n(),
    mean_change   = mean(change),
    median_change = median(change),
    p25           = quantile(change, .25),
    p75           = quantile(change, .75),
    share_up      = mean(change > 0),
    .groups = "drop"
  )
message("Within-charity change in donation share (post minus pre):")
print(change_summary)

# ---- 5. Plot (skipped if ggplot2 unavailable) -----------------------------------

if (requireNamespace("ggplot2", quietly = TRUE)) {
library(ggplot2)
p <- event_summary |>
  filter(event_year >= -3, event_year <= 3) |>
  pivot_longer(c(mean_share, median_share),
               names_to = "stat", values_to = "share") |>
  ggplot(aes(event_year, share, colour = stat)) +
  geom_line() + geom_point() +
  geom_vline(xintercept = 0, linetype = "dashed") +
  facet_wrap(~is_startup, labeller = labeller(
    is_startup = c(`FALSE` = "Established pre-endorsement",
                   `TRUE`  = "Start-up (registered ~with endorsement)"))) +
  scale_y_continuous(labels = scales::percent) +
  labs(
    title = "Donations & bequests share of gross income around DGR endorsement",
    subtitle = "Event year 0 = FY of endorsement (partial exposure); non-ancillary switchers",
    x = "Years relative to endorsement FY", y = "Donation share", colour = NULL
  ) +
  theme_minimal()

ggsave(file.path(out_dir, "event_time_plot.png"), p,
       width = 9, height = 5, dpi = 150)
} else {
  message("ggplot2 not installed; skipping plot.")
}

# ---- 6. Dollar levels & revenue components ------------------------------------
#
# Flat *share* can hide growth in *levels* if total income grows too. Also the
# PAF/PuAF channel: ancillary-fund grants to newly-endorsed DGRs should show up
# in donations_and_bequests (or sometimes all_other_revenue / other_income) —
# no recipient-level grants data exists, so component growth is the best proxy.

est <- switchers |> filter(!is_startup)

levels_summary <- est |>
  group_by(event_year) |>
  summarise(
    n                  = n(),
    med_donations      = median(donations_and_bequests, na.rm = TRUE),
    med_total_income   = median(total_gross_income, na.rm = TRUE),
    med_other_revenue  = median(all_other_revenue, na.rm = TRUE),
    med_other_income   = median(other_income, na.rm = TRUE),
    med_govt_revenue   = median(revenue_from_government, na.rm = TRUE),
    .groups = "drop"
  ) |>
  arrange(event_year)

write.csv(levels_summary, file.path(out_dir, "levels_by_event_year.csv"),
          row.names = FALSE)
message("Median dollar levels by event year (established switchers):")
print(levels_summary, n = Inf)

# Within-charity dollar growth: post (>= +1) vs pre (< 0), same charities.
component_change <- est |>
  group_by(abn) |>
  summarise(
    don_pre   = mean(donations_and_bequests[event_year < 0], na.rm = TRUE),
    don_post  = mean(donations_and_bequests[event_year >= 1], na.rm = TRUE),
    inc_pre   = mean(total_gross_income[event_year < 0], na.rm = TRUE),
    inc_post  = mean(total_gross_income[event_year >= 1], na.rm = TRUE),
    oth_pre   = mean(coalesce(all_other_revenue[event_year < 0], 0) +
                       coalesce(other_income[event_year < 0], 0), na.rm = TRUE),
    oth_post  = mean(coalesce(all_other_revenue[event_year >= 1], 0) +
                       coalesce(other_income[event_year >= 1], 0), na.rm = TRUE),
    .groups = "drop"
  ) |>
  filter(is.finite(don_pre), is.finite(don_post))

levels_change_summary <- component_change |>
  summarise(
    n                  = n(),
    med_don_change     = median(don_post - don_pre),
    med_don_pct_change = median((don_post - don_pre) /
                                  pmax(don_pre, 1)) ,
    share_don_up       = mean(don_post > don_pre),
    med_inc_pct_change = median((inc_post - inc_pre) / pmax(inc_pre, 1)),
    share_inc_up       = mean(inc_post > inc_pre),
    med_oth_change     = median(oth_post - oth_pre),
    share_oth_up       = mean(oth_post > oth_pre)
  )
message("Within-charity dollar changes, post vs pre (established switchers):")
print(levels_change_summary, width = Inf)

# ---- 7. Anticipation test ------------------------------------------------------
#
# If charities ramp up fundraising while their DGR application is in flight,
# event year -1 is already "treated". Test: within charities observed at BOTH
# -2 and -1 (balanced), did the share/levels rise between -2 and -1?

antic <- est |>
  filter(event_year %in% c(-2, -1)) |>
  select(abn, event_year, donation_share, donations_and_bequests) |>
  pivot_wider(names_from = event_year,
              values_from = c(donation_share, donations_and_bequests)) |>
  filter(!is.na(`donation_share_-2`), !is.na(`donation_share_-1`))

antic_summary <- antic |>
  summarise(
    n                = n(),
    mean_share_m2    = mean(`donation_share_-2`),
    mean_share_m1    = mean(`donation_share_-1`),
    median_share_m2  = median(`donation_share_-2`),
    median_share_m1  = median(`donation_share_-1`),
    share_up         = mean(`donation_share_-1` > `donation_share_-2`),
    med_don_m2       = median(`donations_and_bequests_-2`),
    med_don_m1       = median(`donations_and_bequests_-1`)
  )
message("Anticipation test (balanced -2 vs -1, established switchers):")
print(antic_summary, width = Inf)

# ---- 8. Baseline-dependence split ----------------------------------------------
#
# Split established switchers by pre-period donation dependence: low (<10%),
# mid (10-50%), high (>50%). The aggregate mean is dominated by the high group.

dep_split <- est |>
  group_by(abn) |>
  mutate(baseline_share = mean(donation_share[event_year < 0])) |>
  ungroup() |>
  filter(!is.na(baseline_share)) |>
  mutate(baseline_group = cut(baseline_share, c(-Inf, .1, .5, Inf),
                              labels = c("low (<10%)", "mid (10-50%)",
                                         "high (>50%)")))

dep_summary <- dep_split |>
  group_by(baseline_group, period = if_else(event_year < 0, "pre",
                                            if_else(event_year >= 1, "post", "partial"))) |>
  summarise(
    n_obs        = n(),
    mean_share   = mean(donation_share),
    median_share = median(donation_share),
    med_donations = median(donations_and_bequests),
    .groups = "drop"
  ) |>
  filter(period != "partial") |>
  arrange(baseline_group, desc(period))

write.csv(dep_summary, file.path(out_dir, "baseline_dependence_split.csv"),
          row.names = FALSE)
message("Donation share by baseline-dependence group, pre vs post:")
print(dep_summary, n = Inf)

# ---- 9. Dip diagnosis: composition vs real within-cohort pattern ---------------
#
# The event-time medians pool cohorts observed over different calendar years:
# event -4 exists only for the 2023 cohort (calendar 2019), -2 pools all
# cohorts (incl. COVID years). Check the pattern within each endorsement
# cohort separately, and by calendar year, to see if the -4 -> -2 "dip" is
# a composition artefact.

cohort_by_event <- est |>
  group_by(endorsement_fy, event_year) |>
  summarise(n = n(),
            med_donations = median(donations_and_bequests),
            med_share     = median(donation_share),
            .groups = "drop") |>
  arrange(endorsement_fy, event_year)
write.csv(cohort_by_event, file.path(out_dir, "cohort_by_event_year.csv"),
          row.names = FALSE)
message("Median donations by cohort x event year (composition check):")
print(cohort_by_event, n = Inf)

calendar_effect <- est |>
  group_by(ais_year) |>
  summarise(n = n(), med_donations = median(donations_and_bequests),
            .groups = "drop")
message("Median donations by calendar AIS year (switchers pooled):")
print(calendar_effect, n = Inf)

# ---- 10. Inflation adjustment ---------------------------------------------------
#
# CPI, Australia (ABS 6401.0), financial-year average index, 2019=100 base.
# Values through FY2024; nominal dollars deflated to FY2019 dollars.
cpi <- tibble::tribble(
  ~ais_year, ~cpi_index,
  2019, 100.0,
  2020, 101.4,   # +1.4%
  2021, 103.1,   # +1.7%
  2022, 107.2,   # +4.0%
  2023, 114.7,   # +7.0%
  2024, 119.4    # +4.1%
)

est_real <- est |>
  left_join(cpi, by = "ais_year") |>
  mutate(donations_real = donations_and_bequests * 100 / cpi_index,
         income_real    = total_gross_income     * 100 / cpi_index)

real_levels <- est_real |>
  group_by(event_year) |>
  summarise(n = n(),
            med_donations_nominal = median(donations_and_bequests),
            med_donations_real    = median(donations_real),
            med_income_real       = median(income_real),
            .groups = "drop") |>
  arrange(event_year)
write.csv(real_levels, file.path(out_dir, "levels_real_by_event_year.csv"),
          row.names = FALSE)
message("Real (FY2019 dollars) median levels by event year:")
print(real_levels, n = Inf)

real_change <- est_real |>
  group_by(abn) |>
  summarise(
    don_pre  = mean(donations_real[event_year < 0]),
    don_post = mean(donations_real[event_year >= 1]),
    inc_pre  = mean(income_real[event_year < 0]),
    inc_post = mean(income_real[event_year >= 1]),
    .groups = "drop"
  ) |>
  filter(is.finite(don_pre), is.finite(don_post)) |>
  summarise(
    n                  = n(),
    med_don_change     = median(don_post - don_pre),
    med_don_pct_change = median((don_post - don_pre) / pmax(don_pre, 1)),
    share_don_up       = mean(don_post > don_pre),
    med_inc_pct_change = median((inc_post - inc_pre) / pmax(inc_pre, 1))
  )
message("Within-charity REAL dollar changes, post vs pre:")
print(real_change, width = Inf)

# ---- 11. Three-cohort comparison: never / switcher / always ---------------------
#
# Never- and always-DGR charities have no event time, so compare in calendar
# time: median donations and donation share by ais_year, plus within-charity
# growth 2019->2024 (balanced ends). "Always" = endorsed before the panel
# starts (pre-FY2019); "never" = no endorsement record (caveat: small residual
# of failed API lookups). Ancillary funds and switcher start-ups excluded.

cohort3 <- master |>
  mutate(
    fy_end_m       = fy_end_month(financial_year_end),
    endorsement_fy = if_else(
      is.na(dgr_endorsed_from), NA_real_,
      year(dgr_endorsed_from) + as.integer(month(dgr_endorsed_from) > fy_end_m)
    ),
    excl_anc = coalesce(is_ancillary, is_ancillary_provisional, FALSE) |
      coalesce(dgr_item_number == 2L, FALSE),
    cohort3 = case_when(
      is.na(dgr_endorsed_from)                        ~ "never",
      endorsement_fy < 2019                           ~ "always",
      abn %in% (est |> distinct(abn) |> pull(abn))    ~ "switcher",
      TRUE                                            ~ NA_character_  # other endorsees (start-ups, no pre/post, 2024+)
    )
  ) |>
  filter(!excl_anc, !is.na(cohort3)) |>
  select(abn, cohort3)

panel3 <- panel |>
  inner_join(cohort3, by = "abn") |>
  left_join(cpi, by = "ais_year") |>
  filter(!is.na(total_gross_income), total_gross_income >= MIN_INCOME,
         !is.na(donations_and_bequests), donations_and_bequests >= 0) |>
  mutate(donation_share = pmin(donations_and_bequests / total_gross_income, 1),
         donations_real = donations_and_bequests * 100 / cpi_index)

cohort3_by_year <- panel3 |>
  group_by(cohort3, ais_year) |>
  summarise(n = n(),
            med_donations_real = median(donations_real),
            mean_share         = mean(donation_share),
            median_share       = median(donation_share),
            .groups = "drop") |>
  arrange(cohort3, ais_year)
write.csv(cohort3_by_year, file.path(out_dir, "three_cohort_by_year.csv"),
          row.names = FALSE)
message("Three-cohort comparison by calendar year (real FY2019 $):")
print(cohort3_by_year, n = Inf)

# Within-charity real growth 2019 -> 2024, balanced (observed in both years).
growth3 <- panel3 |>
  filter(ais_year %in% c(2019, 2024)) |>
  distinct(abn, ais_year, .keep_all = TRUE) |>  # rare source dups within vintage
  select(abn, cohort3, ais_year, donations_real, donation_share) |>
  pivot_wider(names_from = ais_year,
              values_from = c(donations_real, donation_share)) |>
  filter(!is.na(donations_real_2019), !is.na(donations_real_2024))

growth3_summary <- growth3 |>
  group_by(cohort3) |>
  summarise(
    n                  = n(),
    med_real_growth    = median((donations_real_2024 - donations_real_2019) /
                                  pmax(donations_real_2019, 1)),
    share_don_up       = mean(donations_real_2024 > donations_real_2019),
    med_share_2019     = median(donation_share_2019),
    med_share_2024     = median(donation_share_2024),
    med_share_change   = median(donation_share_2024 - donation_share_2019),
    .groups = "drop"
  )
write.csv(growth3_summary, file.path(out_dir, "three_cohort_growth.csv"),
          row.names = FALSE)
message("Within-charity real donation growth 2019->2024 by cohort (balanced):")
print(growth3_summary, width = Inf)

# ---- 12. Placebo event-time data for comparison cohorts -------------------------
#
# For never/always charities, assign a placebo "endorsement" FY drawn from the
# switcher cohort distribution (2020-2023, proportional), then compute the same
# event-time profile of median real donations. Flat placebo lines through the
# fake event make the switcher step interpretable. Seeded for reproducibility.

set.seed(42)
cohort_weights <- est |>
  distinct(abn, endorsement_fy) |>
  count(endorsement_fy) |>
  mutate(w = n / sum(n))

placebo_assign <- cohort3 |>
  filter(cohort3 %in% c("never", "always")) |>
  mutate(placebo_fy = sample(cohort_weights$endorsement_fy, dplyr::n(),
                             replace = TRUE, prob = cohort_weights$w))

event_profile <- bind_rows(
  est_real |>
    transmute(cohort_plot = "switcher", abn, event_year, donations_real),
  panel3 |>
    inner_join(placebo_assign |> select(abn, placebo_fy), by = "abn") |>
    transmute(cohort_plot = cohort3,
              abn, event_year = ais_year - placebo_fy, donations_real)
) |>
  filter(event_year >= -3, event_year <= 3) |>
  group_by(cohort_plot, event_year) |>
  summarise(n = n(), med_donations_real = median(donations_real),
            .groups = "drop") |>
  group_by(cohort_plot) |>
  mutate(index = 100 * med_donations_real /
           med_donations_real[event_year == -1]) |>
  ungroup()

write.csv(event_profile, file.path(out_dir, "placebo_event_profile.csv"),
          row.names = FALSE)
message("Placebo event-time profile written.")

# Switcher cohort x calendar-year real medians for small multiples.
cohort_calendar <- est_real |>
  group_by(endorsement_fy, ais_year) |>
  summarise(n = n(), med_donations_real = median(donations_real),
            .groups = "drop")
write.csv(cohort_calendar, file.path(out_dir, "cohort_calendar_real.csv"),
          row.names = FALSE)

message("Done. Outputs in analysis/dgr_event_study/")
