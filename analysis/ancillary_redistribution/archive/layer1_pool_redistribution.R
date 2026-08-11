# Layer 1 walkthrough: ancillary-fund pool redistribution, today vs reform.
#
# What it does: decomposes the reform_scenarios model step by step — pool,
#   eligible bases, implied incumbent dilution, and cohort slices under the
#   three allocation rules (revenue / donations / count) — comparing the
#   current DGR-only base with the expanded post-reform base.
# Depends on: data/analytical/dgr_gap_analysis.parquet,
#             data/analytical/ancillary_funds_timeseries.csv
# Snapshot: 2026-07-19 pipeline build (AIS 2024, ancillary pool 2023-24).
#
# Optional refinement: not every charity would gain DGR under the modelled
# reform. If a reform-eligibility file exists (one row per ABN that WOULD be
# eligible, column `abn`), the expanded base is restricted to current DGRs +
# flagged charities. Otherwise all charities are assumed eligible (matching
# build_reform_scenarios()).
ELIGIBILITY_FILE <- "analysis/reform_eligibility_flags.csv"  # not yet provided

suppressPackageStartupMessages({library(dplyr); library(readr)})

SUBTYPES <- c("disaster_preparedness", "human_rights",
              "injury_prevention", "neighbourhood_house")

# ---- 1. The pool ------------------------------------------------------------
anc <- read_csv("data/analytical/ancillary_funds_timeseries.csv", show_col_types = FALSE)
latest_fy <- max(anc$income_year)
pool <- sum(anc$distributions_made[anc$income_year == latest_fy])
cat("Pool (", latest_fy, "PAF+PuAF distributions): $", round(pool / 1e6), "m\n\n")

# ---- 2. Charity-level base (latest AIS year, ancillary funds excluded) ------
gap <- arrow::read_parquet("data/analytical/dgr_gap_analysis.parquet")
latest <- gap |>
  filter(ais_year == max(ais_year)) |>
  mutate(revenue   = pmax(coalesce(total_gross_income, 0), 0),
         donations = pmax(coalesce(donations_and_bequests, 0), 0))

# ---- 3. Reform eligibility --------------------------------------------------
if (file.exists(ELIGIBILITY_FILE)) {
  elig_abns <- read_csv(ELIGIBILITY_FILE, show_col_types = FALSE)$abn
  latest <- latest |> mutate(reform_eligible = has_dgr | abn %in% elig_abns)
  cat("Eligibility flags loaded:", length(elig_abns), "flagged ABNs;",
      sum(latest$reform_eligible & !latest$has_dgr), "newly eligible in base\n\n")
} else {
  latest <- latest |> mutate(reform_eligible = TRUE)
  cat("No eligibility file found (", ELIGIBILITY_FILE, ") — assuming ALL",
      "charities eligible under reform, as in build_reform_scenarios().\n\n")
}

dgr_base    <- latest |> filter(has_dgr)          # who can receive today
reform_base <- latest |> filter(reform_eligible)  # who could receive under reform

bases <- function(d) c(revenue = sum(d$revenue), donations = sum(d$donations), count = nrow(d))
b_now <- bases(dgr_base); b_reform <- bases(reform_base)

cat("Base today:  ", nrow(dgr_base), "DGR charities | revenue $",
    round(b_now["revenue"] / 1e9, 1), "bn | donations $",
    round(b_now["donations"] / 1e9, 1), "bn\n")
cat("Base reform: ", nrow(reform_base), "charities | revenue $",
    round(b_reform["revenue"] / 1e9, 1), "bn | donations $",
    round(b_reform["donations"] / 1e9, 1), "bn\n\n")

# ---- 4. Implied incumbent dilution ------------------------------------------
cat("=== Incumbent dilution: share of pool current DGRs keep under reform ===\n")
for (nm in names(b_now)) {
  keep <- b_now[nm] / b_reform[nm]
  cat(sprintf("%-9s rule: keep %5.1f%% -> $%4.0fm stays, $%4.0fm moves to newly eligible\n",
              nm, 100 * keep, pool * keep / 1e6, pool * (1 - keep) / 1e6))
}

# ---- 5. Cohort slices: today vs reform --------------------------------------
cat("\n=== Cohort slice of pool: today (DGR base) vs reform (eligible base) ===\n")
results <- list()
for (st in SUBTYPES) {
  m  <- latest |> filter(!is.na(target_subtype), grepl(st, target_subtype, fixed = TRUE))
  dgr_members <- m |> filter(has_dgr)
  ne          <- m |> filter(!has_dgr, reform_eligible)
  now_m <- bases(dgr_members); ne_m <- bases(ne)
  for (nm in names(b_now)) {
    results[[length(results) + 1]] <- tibble(
      subtype = st, basis = nm,
      n_newly_eligible  = nrow(ne),
      today_dollars     = pool * now_m[nm] / b_now[nm],
      reform_dollars    = pool * (now_m[nm] + ne_m[nm]) / b_reform[nm],
      newly_elig_dollars = pool * ne_m[nm] / b_reform[nm]
    )
  }
}
res <- bind_rows(results) |>
  mutate(across(ends_with("dollars"), ~ round(.x / 1e6, 1)),
         net_change = reform_dollars - today_dollars)
print(as.data.frame(res), row.names = FALSE)

cat("\nNotes:\n",
    "- 'today' slices assume ancillary funds currently allocate by the same\n",
    "  mechanical rule across all DGRs — illustrative, not observed flows\n",
    "  (recipient-level distribution data is never published).\n",
    "- Fixed-pool view: cohort gains come out of incumbents' share (Layer 1).\n",
    "  Pie growth from increased giving is Layer 2, modelled separately.\n")
