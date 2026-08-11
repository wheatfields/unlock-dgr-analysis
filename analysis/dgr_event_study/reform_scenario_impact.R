# Reform scenario impact: apply the DGR endorsement event-study uplift to the
# post-reform gain/lose mapping (analysis/output_dgr_change_mapping.xlsx).
#
# Scenarios:
#   PC pure change — dgr_reform_status          (gainers AND losers)
#   Expansion      — dgr_reform_status_expansion (same gainers, no losers)
#
# Method:
#   - One row per charity: latest ais_year flags (307 ABNs have conflicting
#     statuses across years; latest wins, consistent with valuing on latest
#     financials). Malformed ABNs (not 11 digits) excluded.
#   - Join latest-year AIS financials (donations_and_bequests) per charity.
#   - Uplift on gainers' donation base: central +30% (within-charity real
#     median from event study), high +47% (nominal median). An anticipation-
#     robust check (baseline restricted to event years <= -2) gives +29%, so
#     the central estimate stands without a separate low case. (A former 0.24
#     "low" constant could not be reproduced from the data and was dropped,
#     2026-07-29; see analysis/dgr_event_study/uplift_calculation.ipynb.)
#   - Losers (PC only): donation base at risk, symmetric downside ASSUMED
#     (untested — we only observe gains).
#
# Outputs: reform_scenario_impact.csv, reform_group_bases.csv

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(arrow)
})

root    <- here::here()
out_dir <- file.path(root, "analysis", "dgr_event_study")

UPLIFT_CENTRAL <- 0.30   # within-charity real median (anticipation-robust: 0.29)
UPLIFT_HIGH    <- 0.47   # nominal within-charity median

mapping <- readxl::read_excel(
  file.path(root, "analysis", "output_dgr_change_mapping.xlsx"),
  col_types = c("text", "text", "numeric", "logical", "text", "text", "text")
) |>
  filter(grepl("^\\d{11}$", abn)) |>
  group_by(abn) |>
  slice_max(ais_year, n = 1, with_ties = FALSE, na_rm = FALSE) |>
  ungroup() |>
  mutate(
    group = case_when(
      has_dgr == "N" & dgr_reform_status == "Y" ~ "gainer",
      has_dgr == "Y" & dgr_reform_status == "N" ~ "loser",
      has_dgr == "Y" & dgr_reform_status == "Y" ~ "keeper",
      TRUE                                      ~ "never"
    )
  )

panel <- read_parquet(file.path(root, "data/analytical/charity_financials_panel.parquet"))

latest_fin <- panel |>
  filter(!is.na(donations_and_bequests), donations_and_bequests >= 0) |>
  group_by(abn) |>
  slice_max(ais_year, n = 1, with_ties = FALSE) |>
  ungroup() |>
  select(abn, fin_year = ais_year, donations_and_bequests, total_gross_income)

df <- mapping |>
  left_join(latest_fin, by = "abn")

# ---- Group donation bases -----------------------------------------------------

bases <- df |>
  group_by(group, is_ancillary) |>
  summarise(
    n_charities     = n(),
    n_with_fin      = sum(!is.na(donations_and_bequests)),
    donations_total = sum(donations_and_bequests, na.rm = TRUE),
    donations_median = median(donations_and_bequests[donations_and_bequests > 0],
                              na.rm = TRUE),
    .groups = "drop"
  )
write.csv(bases, file.path(out_dir, "reform_group_bases.csv"), row.names = FALSE)
message("Group donation bases (latest AIS year per charity):")
print(bases, n = Inf, width = Inf)

# ---- Scenario impacts ----------------------------------------------------------
# Ancillary funds excluded from uplift arithmetic: they are grant-making
# vehicles, not fundraising charities; their donations_and_bequests are
# contributions from founders, a different behavioural channel.

gain_base <- df |>
  filter(group == "gainer", !is_ancillary) |>
  summarise(v = sum(donations_and_bequests, na.rm = TRUE)) |> pull(v)

lose_base <- df |>
  filter(group == "loser", !is_ancillary) |>
  summarise(v = sum(donations_and_bequests, na.rm = TRUE)) |> pull(v)

impact <- tibble(
  scenario = c("PC pure change", "Expansion"),
  n_gainers = sum(df$group == "gainer" & !df$is_ancillary),
  gainer_donation_base = gain_base,
  uplift_central = gain_base * UPLIFT_CENTRAL,
  uplift_high    = gain_base * UPLIFT_HIGH,
  n_losers = c(sum(df$group == "loser" & !df$is_ancillary), 0),
  loser_donation_base_at_risk = c(lose_base, 0),
  # Net central: gains minus symmetric loss assumption (PC only)
  net_central = c(gain_base * UPLIFT_CENTRAL - lose_base * UPLIFT_CENTRAL,
                  gain_base * UPLIFT_CENTRAL)
)
write.csv(impact, file.path(out_dir, "reform_scenario_impact.csv"),
          row.names = FALSE)
message("Scenario impact (non-ancillary charities; latest-year donations):")
print(impact, width = Inf)

# Ancillary losers under PC — reported separately (structural change to the
# grant-making pool, not a fundraising effect).
anc_losers <- df |> filter(group == "loser", is_ancillary)
message(sprintf(
  "PC scenario: %d ancillary funds lose DGR (reported separately; their pool role is the Layer 1 analysis).",
  nrow(anc_losers)
))
