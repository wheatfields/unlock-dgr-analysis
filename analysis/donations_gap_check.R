# Donations-gap plausibility check (Layer 2 support) — writes nothing.
# Question: within size strata, do DGR charities receive systematically more
# donations than non-DGR charities? Cross-sectional; selection not causation.
suppressPackageStartupMessages({library(dplyr); library(arrow); library(tidyr)})

gap <- read_parquet("data/analytical/dgr_gap_analysis.parquet") |>
  group_by(abn) |>
  slice_max(ais_year, n = 1, with_ties = FALSE) |>
  ungroup() |>
  filter(!is.na(charity_size), !is.na(total_gross_income), total_gross_income > 0)

cat("=== 1. Donations by DGR status x size (all charities, latest yr) ===\n")
gap |>
  group_by(charity_size, has_dgr) |>
  summarise(
    n = n(),
    pct_any_donations = round(100 * mean(donations_and_bequests > 0, na.rm = TRUE), 1),
    med_donations_if_any = median(donations_and_bequests[donations_and_bequests > 0], na.rm = TRUE),
    med_don_dep = round(median(donation_dependence, na.rm = TRUE), 4),
    .groups = "drop") |>
  as.data.frame() |> print(row.names = FALSE)

cat("\n=== 2. The gap ratio: DGR vs non-DGR median donations (donors only) ===\n")
gap |>
  filter(donations_and_bequests > 0) |>
  group_by(charity_size, has_dgr) |>
  summarise(med = median(donations_and_bequests), .groups = "drop") |>
  pivot_wider(names_from = has_dgr, values_from = med, names_prefix = "dgr_") |>
  mutate(ratio = round(dgr_TRUE / dgr_FALSE, 2)) |>
  as.data.frame() |> print(row.names = FALSE)

cat("\n=== 3. Same, within the 4 purpose-proxy strata (Small charities only) ===\n")
proxies <- c(
  neighbourhood_house   = "advancing_social_or_public_welfare",
  disaster_preparedness = "advancing_security_or_safety_of_australia_or_australian_public",
  injury_prevention     = "advancing_health",
  human_rights          = "promoting_or_protecting_human_rights")
for (nm in names(proxies)) {
  d <- gap |>
    filter(.data[[proxies[nm]]] == "Y", charity_size == "Small",
           donations_and_bequests > 0)
  r <- d |>
    group_by(has_dgr) |>
    summarise(n = n(), med = median(donations_and_bequests), .groups = "drop")
  ratio <- round(r$med[r$has_dgr] / r$med[!r$has_dgr], 2)
  cat(sprintf("%-22s  non-DGR n=%4d med=$%-8s | DGR n=%4d med=$%-8s | ratio %.2f\n",
      nm, r$n[!r$has_dgr], format(r$med[!r$has_dgr], big.mark = ","),
      r$n[r$has_dgr], format(r$med[r$has_dgr], big.mark = ","), ratio))
}

cat("\n=== 4. Extensive margin: % receiving ANY donations (Small, by proxy) ===\n")
for (nm in names(proxies)) {
  d <- gap |> filter(.data[[proxies[nm]]] == "Y", charity_size == "Small")
  r <- d |>
    group_by(has_dgr) |>
    summarise(pct = round(100 * mean(donations_and_bequests > 0, na.rm = TRUE), 1),
              .groups = "drop")
  cat(sprintf("%-22s  non-DGR %.1f%%  vs  DGR %.1f%%\n",
      nm, r$pct[!r$has_dgr], r$pct[r$has_dgr]))
}
