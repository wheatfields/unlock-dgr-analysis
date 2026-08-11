# Ad-hoc PAF/PuAF key statistics and cross-source reconciliation
# Run: Rscript analysis/paf_puaf_reconciliation.R
suppressPackageStartupMessages({
  library(dplyr); library(arrow); library(readr)
})

listing <- read_parquet("data/processed/dgr_listing.parquet")
master  <- read_parquet("data/analytical/charity_master.parquet")
anc_ts  <- read_csv("data/analytical/ancillary_funds_timeseries.csv", show_col_types = FALSE)
dgr_cnt <- read_csv("data/analytical/dgr_counts_by_type.csv", show_col_types = FALSE)

cat("=== 1. DGR listing (ABN Lookup, snapshot", unique(listing$source_file)[1], ") ===\n")
ent <- listing |> filter(record_level == "entity")
cat("Entity records:", nrow(ent), "\n")
print(ent |> count(dgr_item_number, dgr_item_type, sort = TRUE))
item2 <- ent |> filter(dgr_item_number == 2)
cat("Item 2 (ancillary) entities:", nrow(item2), "distinct ABNs:", n_distinct(item2$abn), "\n")
cat("Item 2 ABN status breakdown:\n"); print(item2 |> count(abn_status))
cat("Fund-level records:", sum(listing$record_level == "fund"),
    "distinct operator ABNs:", n_distinct(listing$abn[listing$record_level == "fund"]), "\n\n")

cat("=== 2. ATO Taxation Statistics 2023-24 ===\n")
t3 <- dgr_cnt |> filter(grepl("Ancillary", dgr_category))
print(t3 |> select(dgr_category, n))
cat("Table 3 PAF+PuAF endorsements:", sum(t3$n), "\n")
t4 <- anc_ts |> filter(income_year == "2023-24")
print(t4 |> select(fund_type, n_funds, donations_received, distributions_made, net_assets))
cat("Table 4 PAF+PuAF fund count:", sum(t4$n_funds),
    "| total distributions: $", format(sum(t4$distributions_made), big.mark = ","), "\n\n")

cat("=== 3. Reconciliation: listing Item 2 vs ATO counts ===\n")
cat("ABN listing Item 2:", nrow(item2),
    "| ATO Table 3 (PAF 2406 + PuAF 1404):", sum(t3$n),
    "| ATO Table 4 2023-24 n_funds:", sum(t4$n_funds), "\n")
cat("Diffs: listing - table3 =", nrow(item2) - sum(t3$n),
    "; listing - table4 =", nrow(item2) - sum(t4$n_funds), "\n\n")

cat("=== 4. ACNC register join (charity_master) ===\n")
cat("is_ancillary (Item 2, matched to register):", sum(master$is_ancillary, na.rm = TRUE), "\n")
cat("is_ancillary_provisional (name match):", sum(master$is_ancillary_provisional, na.rm = TRUE), "\n")
cat("Withheld ABNs on register (unjoinable):", sum(is.na(master$abn)), "\n")
cat("Item 2 ABNs NOT on ACNC register:",
    nrow(item2 |> anti_join(master |> filter(!is.na(abn)), by = "abn")), "\n")
anc_named_split <- master |>
  filter(is_ancillary %in% TRUE) |>
  left_join(item2 |> distinct(abn, dgr_item_type), by = "abn")
cat("PAF/PuAF split of register-matched ancillary funds (from listing item type):\n")
print(anc_named_split |> count(dgr_item_type, sort = TRUE))

cat("\n=== 5. PAF/PuAF pool trends (Layer 1 context) ===\n")
trend <- anc_ts |>
  filter(income_year >= "2019-20") |>
  group_by(income_year) |>
  summarise(n_funds = sum(n_funds),
            donations_in = sum(donations_received),
            distributions_out = sum(distributions_made),
            net_assets = sum(net_assets), .groups = "drop") |>
  mutate(payout_rate_pct = round(100 * distributions_out / net_assets, 1))
print(trend, width = 120)

paf24 <- anc_ts |> filter(income_year == "2023-24", fund_type == "PAF")
puaf24 <- anc_ts |> filter(income_year == "2023-24", fund_type == "PuAF")
cat("\n2023-24 payout vs regulatory minimum: PAF",
    round(100 * paf24$distributions_made / paf24$net_assets, 1), "% (min 5%) | PuAF",
    round(100 * puaf24$distributions_made / puaf24$net_assets, 1), "% (min 4%)\n")

cat("\n=== 6. Ancillary share of DGR system ===\n")
cat("PAF+PuAF endorsements as share of all DGR endorsements:",
    round(100 * sum(t3$n) / sum(dgr_cnt$n), 1), "% (", sum(t3$n), "of", sum(dgr_cnt$n), ")\n")
cat("Item 2 share of entity-level listing:",
    round(100 * nrow(item2) / nrow(ent), 1), "%\n")
