# Ancillary-fund pool redistribution under the two DGR reform scenarios.
#
# Question: the $1.5bn/yr PAF/PuAF pool may only be granted to DGR Item 1
# charities. Who can receive it before vs after reform, and how much moves?
#
# Scenarios (from analysis/output_dgr_change_mapping.xlsx):
#   PC pure change — gainers enter the eligible base, losers exit
#   Expansion      — gainers enter, nobody exits
#
# NOTE: the mapping file flags 1,209 ancillary funds as PC losers. The PC's
# final report (Future Foundations for Giving, 2024) retains ancillary funds
# ("giving funds") with DGR intact — its removals target recipient activity
# classes, not Item 2 conduits. We therefore override ancillary funds to
# retain DGR under both scenarios; the flags appear to be a mapping artefact
# of applying activity-class rules to ancillary funds' generic ACNC subtypes.
#
# Allocation rules are mechanical bounds (as in build_reform_scenarios):
#   revenue   — pool pro-rata to total gross income
#   donations — pro-rata to donations attracted (fundability proxy)
#   count     — equal per charity
#
# Outputs (analysis/dgr_event_study/):
#   pool_redistribution_scenarios.csv — pool split by scenario x rule
#   pool_at_risk_pc.csv               — PC-losing ancillary funds' pool share

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(arrow)
})

root    <- here::here()
out_dir <- file.path(root, "analysis", "dgr_event_study")

# ---- 1. Pool ----------------------------------------------------------------
anc <- read_csv(file.path(root, "data/analytical/ancillary_funds_timeseries.csv"),
                show_col_types = FALSE)
latest_fy <- max(anc$income_year)
pool <- sum(anc$distributions_made[anc$income_year == latest_fy])
cat("Pool (", latest_fy, "PAF+PuAF distributions): $", round(pool / 1e6), "m\n\n")

# ---- 2. Scenario mapping (one row per charity, latest-year flags) ------------
mapping <- readxl::read_excel(
  file.path(root, "analysis", "output_dgr_change_mapping.xlsx"),
  col_types = c("text", "text", "numeric", "logical", "text", "text", "text")
) |>
  filter(grepl("^\\d{11}$", abn)) |>
  group_by(abn) |>
  slice_max(ais_year, n = 1, with_ties = FALSE, na_rm = FALSE) |>
  ungroup() |>
  select(abn, is_ancillary_map = is_ancillary, has_dgr_map = has_dgr,
         pc = dgr_reform_status, exp = dgr_reform_status_expansion)

# Override: ancillary funds keep DGR under both scenarios (see NOTE above).
n_anc_overridden <- sum(mapping$is_ancillary_map & mapping$has_dgr_map == "Y" &
                          mapping$pc == "N", na.rm = TRUE)
mapping <- mapping |>
  mutate(pc  = if_else(is_ancillary_map & has_dgr_map == "Y", "Y", pc),
         exp = if_else(is_ancillary_map & has_dgr_map == "Y", "Y", exp))
cat("Ancillary funds overridden to retain DGR (PC scenario):", n_anc_overridden,
    "— flags in mapping xlsx look like an artefact; PC report keeps ancillary funds' DGR.\n\n")

# ---- 3. Charity financials (latest AIS year, ancillary excluded from base) ---
panel <- read_parquet(file.path(root, "data/analytical/charity_financials_panel.parquet"))
latest_fin <- panel |>
  group_by(abn) |>
  slice_max(ais_year, n = 1, with_ties = FALSE) |>
  ungroup() |>
  transmute(abn,
            revenue   = pmax(coalesce(total_gross_income, 0), 0),
            donations = pmax(coalesce(donations_and_bequests, 0), 0))

df <- mapping |>
  filter(!is_ancillary_map) |>              # recipients, not grant-makers
  left_join(latest_fin, by = "abn") |>
  mutate(revenue = coalesce(revenue, 0), donations = coalesce(donations, 0),
         group_pc = case_when(
           has_dgr_map == "Y" & pc == "Y" ~ "incumbent",
           has_dgr_map == "N" & pc == "Y" ~ "gainer",
           has_dgr_map == "Y" & pc == "N" ~ "loser",
           TRUE                           ~ "outside"
         ),
         group_exp = case_when(
           has_dgr_map == "Y"              ~ "incumbent",
           has_dgr_map == "N" & exp == "Y" ~ "gainer",
           TRUE                            ~ "outside"
         ))

bases <- function(d) c(revenue = sum(d$revenue), donations = sum(d$donations),
                       count = nrow(d))

# ---- 4. Pool split by scenario x rule -----------------------------------------
split_pool <- function(d, group_col, scenario_name) {
  elig <- d |> filter(.data[[group_col]] %in% c("incumbent", "gainer"))
  tot  <- bases(elig)
  bind_rows(lapply(c("revenue", "donations", "count"), function(rule_nm) {
    elig |>
      group_by(grp = .data[[group_col]]) |>
      summarise(base = c(revenue = sum(revenue), donations = sum(donations),
                         count = n())[[rule_nm]], .groups = "drop") |>
      mutate(scenario = scenario_name, rule = rule_nm,
             share = base / tot[[rule_nm]],
             dollars_m = pool * share / 1e6) |>
      select(scenario, rule, grp, share, dollars_m)
  }))
}

today <- df |>
  filter(has_dgr_map == "Y") |>
  mutate(grp_today = "incumbent")
res <- bind_rows(
  split_pool(df, "group_pc",  "PC pure change"),
  split_pool(df, "group_exp", "Expansion")
)
write.csv(res, file.path(out_dir, "pool_redistribution_scenarios.csv"),
          row.names = FALSE)

cat("=== Pool split by scenario and allocation rule ===\n")
res |>
  mutate(share = sprintf("%5.1f%%", 100 * share),
         dollars_m = sprintf("$%4.0fm", dollars_m)) |>
  arrange(scenario, rule, grp) |>
  print(n = Inf)

# Losers' displaced share under PC: what they'd get under each rule TODAY.
cat("\n=== PC losers: pool share they receive today (displaced by reform) ===\n")
tot_today <- bases(today)
losers <- df |> filter(group_pc == "loser")
for (rule in c("revenue", "donations", "count")) {
  b <- bases(losers)[[rule]]
  cat(sprintf("%-9s rule: %5.2f%% of today's pool = $%.0fm displaced\n",
              rule, 100 * b / tot_today[[rule]], pool * b / tot_today[[rule]] / 1e6))
}

# ---- 5. Ancillary funds under PC -----------------------------------------------
# With the override applied, no ancillary funds lose DGR: the $1.5bn pool keeps
# flowing under both scenarios; only the recipient base changes.
cat(sprintf(
  "\n=== Ancillary funds ===\nAll %d DGR ancillary funds retain DGR under both scenarios (override applied);\nthe $%.0fm pool is assumed intact.\n",
  sum(mapping$is_ancillary_map & mapping$has_dgr_map == "Y", na.rm = TRUE),
  pool / 1e6
))
