# Volunteer setup

You don't need Git, GitHub, or this repo. You'll work against Parquet files in the team SharePoint folder using DuckDB. The whole setup takes about 15 minutes.

## What you'll need

1. **R + RStudio** (current versions).
2. **Access to the team SharePoint folder** — Adam will share the link. Sync it to your local machine via the OneDrive client so it appears as a normal folder.
3. **Three R packages**, installed once:

   ```r
   install.packages(c("duckdb", "arrow", "dplyr"))
   ```

## Connect to the data

In a new R script or notebook:

```r
library(duckdb)
library(dplyr)

# Replace with the local path to the synced SharePoint folder
DATA_DIR <- "~/Justice Connect - Unlock DGR/data/latest"

con <- dbConnect(duckdb(), ":memory:")

# Register every Parquet file in the folder as a queryable table
for (f in list.files(DATA_DIR, pattern = "\\.parquet$", full.names = TRUE)) {
  table_name <- tools::file_path_sans_ext(basename(f))
  dbExecute(con, sprintf(
    "CREATE VIEW %s AS SELECT * FROM read_parquet('%s')",
    table_name, f
  ))
}

dbListTables(con)
# [1] "charity_master" "charity_financials" "giving_aggregates"
```

## Query the data

Two equivalent ways. Use whichever feels natural.

**SQL:**
```r
dbGetQuery(con, "
  SELECT has_dgr, COUNT(*) AS n_charities
  FROM charity_master
  GROUP BY has_dgr
")
```

**dplyr:**
```r
tbl(con, "charity_master") |>
  count(has_dgr) |>
  collect()
```

DuckDB is fast — you can query the full ACNC register joined to AIS in a fraction of a second. Don't pre-filter or sample for performance reasons; just write the query you actually want.

## What's in the data

See `data_dictionary.md` in the same SharePoint folder. Quick orientation:

- **`charity_master`** — one row per registered charity. Columns include ABN, charity name, size, state, ACNC subtype, DGR status flag, and the campaign target category (neighbourhood houses / injury prevention / disaster preparedness / human rights promotion) where applicable.
- **`charity_financials`** — one row per charity-year, with AIS financial items joined to charity attributes.
- **`giving_aggregates`** — ATO/ACPNS aggregate giving series (not per charity).

## Working conventions

- **Notebooks live in your own SharePoint subfolder.** Don't edit the Parquet files. Don't put your work in the `latest/` or `versions/` folders.
- **Name your file `<yourname>_<topic>.R` (or `.qmd`, `.Rmd`).** Add a header comment with what it does and what data it depends on.
- **When your analysis is finalised**, send the file to Adam. He commits it to the project Git repo under `analysis/`. That's how it becomes part of the methodology.
- **Data updates** happen when Adam re-runs the pipeline. Versioned snapshots live in `versions/<date>/`. The `latest/` folder always points to the newest. If you need to anchor your analysis to a specific snapshot, point at the dated folder.
- **Methodology questions** go to Adam. Suggested changes to the methodology — including changes to the subtype mapping — are welcome; raise them in Slack and they'll get reviewed.

## Troubleshooting

- *"Cannot find file"* — your SharePoint folder isn't synced locally yet, or the path is wrong. Check the OneDrive client status.
- *DuckDB query is slow* — first query against a fresh connection has some overhead. Subsequent queries should be sub-second.
- *Schema doesn't match what's in the data dictionary* — Adam may have refreshed the data; pull the latest dictionary from the SharePoint folder.
