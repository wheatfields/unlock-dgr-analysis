# Cohort baseline profiles — exploratory readout (writes nothing)
suppressPackageStartupMessages({library(dplyr); library(arrow); library(tidyr)})

gap  <- read_parquet("data/analytical/dgr_gap_analysis.parquet")
subt <- read_parquet("data/analytical/charity_target_subtypes.parquet")

# Latest year per charity in the cohort
latest <- gap |>
  filter(!is.na(target_subtype)) |>
  group_by(abn) |>
  slice_max(ais_year, n = 1, with_ties = FALSE) |>
  ungroup() |>
  separate_rows(target_subtype, sep = ";")

cat("=== 1. Cohort size, DGR leakage, newly eligible ===\n")
latest |>
  group_by(target_subtype) |>
  summarise(
    n_with_financials = n(),
    n_dgr        = sum(has_dgr),
    pct_dgr      = round(100 * mean(has_dgr), 1),
    n_newly_elig = sum(!has_dgr),
    .groups = "drop") |>
  as.data.frame() |> print()

cat("\n=== 2. Size mix (% of cohort) ===\n")
latest |>
  count(target_subtype, charity_size) |>
  group_by(target_subtype) |>
  mutate(pct = round(100 * n / sum(n), 1)) |>
  select(-n) |>
  pivot_wider(names_from = charity_size, values_from = pct) |>
  as.data.frame() |> print()

cat("\n=== 3. Financial profile of the NEWLY ELIGIBLE (medians, latest yr) ===\n")
latest |>
  filter(!has_dgr) |>
  group_by(target_subtype) |>
  summarise(
    n = n(),
    med_gross_income = median(total_gross_income, na.rm = TRUE),
    med_donations    = median(donations_and_bequests, na.rm = TRUE),
    total_donations_m = round(sum(donations_and_bequests, na.rm = TRUE)/1e6, 1),
    med_don_dep      = round(median(donation_dependence, na.rm = TRUE), 3),
    med_govt_share   = round(median(revenue_from_government / total_gross_income, na.rm = TRUE), 3),
    .groups = "drop") |>
  as.data.frame() |> print()

cat("\n=== 4. Same profile for cohort members WITH DGR (comparison) ===\n")
latest |>
  filter(has_dgr) |>
  group_by(target_subtype) |>
  summarise(
    n = n(),
    med_gross_income = median(total_gross_income, na.rm = TRUE),
    med_donations    = median(donations_and_bequests, na.rm = TRUE),
    total_donations_m = round(sum(donations_and_bequests, na.rm = TRUE)/1e6, 1),
    med_don_dep      = round(median(donation_dependence, na.rm = TRUE), 3),
    .groups = "drop") |>
  as.data.frame() |> print()

cat("\n=== 5. State spread of newly eligible ===\n")
latest |>
  filter(!has_dgr) |>
  count(target_subtype, state) |>
  pivot_wider(names_from = state, values_from = n, values_fill = 0) |>
  as.data.frame() |> print()
