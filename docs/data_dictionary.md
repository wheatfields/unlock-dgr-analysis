# Data dictionary

Schemas for the analytical Parquet files in `data/analytical/` (and the SharePoint `latest/` folder).

> **Note**: this file is a starting template. After the first successful pipeline run, populate the column lists from `arrow::read_parquet(..., as_data_frame = FALSE) |> schema()`.

---

## `charity_master`

One row per registered charity.

| Column | Type | Source | Description |
|---|---|---|---|
| `abn` | string | ACNC register | 11-digit ABN, digits only |
| `charity_name` | string | ACNC register | Registered name |
| `charity_size` | string | ACNC register | ACNC size classification |
| `charity_subtype` | string | ACNC register | ACNC subtype classification |
| `state` | string | ACNC register | State of registered address |
| `registration_status` | string | ACNC register | Active / revoked etc. |
| `has_dgr` | bool | ABN DGR | TRUE if currently endorsed for DGR |
| `dgr_item_numbers` | string | ABN DGR | Pipe-separated list of DGR item numbers |
| `target_category` | string | Manual mapping | One of: neighbourhood_houses, injury_prevention, disaster_preparedness, human_rights_promotion (or NA) |
| `confidence` | string | Manual mapping | high / medium / low |
| `ingestion_date` | date | Pipeline | Date the row was ingested |
| `source_file` | string | Pipeline | Originating raw file |

---

## `charity_financials`

One row per charity-year.

| Column | Type | Source | Description |
|---|---|---|---|
| `abn` | string | ACNC AIS | 11-digit ABN |
| `ais_year` | int | ACNC AIS | AIS reporting year |
| `total_revenue` | numeric | ACNC AIS | (Verify exact column name) |
| `total_donations` | numeric | ACNC AIS | (Verify) |
| `total_expenses` | numeric | ACNC AIS | (Verify) |
| `has_dgr` | bool | charity_master | DGR status as of master snapshot |
| `target_category` | string | charity_master | As above |
| `charity_size` | string | charity_master | As above |
| ... | | | (populate after first build) |

---

## `giving_aggregates`

ATO/ACPNS aggregate giving series. Schema TBD after first ingestion.

| Column | Type | Source | Description |
|---|---|---|---|
| ... | | | (populate after first build) |
