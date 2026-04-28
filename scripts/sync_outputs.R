#' Sync analytical Parquet outputs to the SharePoint folder volunteers query from.
#'
#'   source("scripts/sync_outputs.R")
#'
#' Approach: SharePoint is mounted locally via the OneDrive client (the standard
#' setup on Windows/macOS — SharePoint document libraries appear as a synced
#' folder in your file system). This script copies analytical Parquet files
#' into that folder. The OneDrive client handles the actual upload.
#'
#' Configure SHAREPOINT_PATH to point at the synced library, e.g.:
#'   Windows: "C:/Users/Adam/Justice Connect - Unlock DGR/data"
#'   macOS:   "~/Library/CloudStorage/OneDrive-SharedLibraries-JusticeConnect/Unlock DGR/data"
#'
#' If SharePoint is not synced locally, use the Microsoft Graph API path
#' (see Microsoft365R package) — left as a TODO.

SHAREPOINT_PATH <- Sys.getenv("UNLOCKDGR_SHAREPOINT_PATH", unset = "")

if (!nzchar(SHAREPOINT_PATH)) {
  stop(
    "Set UNLOCKDGR_SHAREPOINT_PATH to your synced SharePoint folder.\n",
    "  In R: Sys.setenv(UNLOCKDGR_SHAREPOINT_PATH = \"<path>\")\n",
    "  Or add to .Renviron in the project root."
  )
}

if (!dir.exists(SHAREPOINT_PATH)) {
  stop("SharePoint path does not exist: ", SHAREPOINT_PATH)
}

source_files <- list.files("data/analytical", pattern = "\\.parquet$",
                            full.names = TRUE)

if (length(source_files) == 0) {
  stop("No analytical Parquet files found. Run scripts/build.R first.")
}

# Copy with a 'latest' subfolder and a dated subfolder for versioning.
latest_dir <- file.path(SHAREPOINT_PATH, "latest")
dated_dir  <- file.path(SHAREPOINT_PATH, "versions", format(Sys.Date(), "%Y%m%d"))
for (d in c(latest_dir, dated_dir)) {
  if (!dir.exists(d)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
}

for (f in source_files) {
  file.copy(f, file.path(latest_dir, basename(f)), overwrite = TRUE)
  file.copy(f, file.path(dated_dir,  basename(f)), overwrite = TRUE)
  message("Synced: ", basename(f))
}

# Also copy the methodology and data dictionary
for (doc in c("docs/methodology.md", "docs/data_dictionary.md",
              "docs/volunteer_setup.md")) {
  if (file.exists(doc)) {
    file.copy(doc, file.path(latest_dir, basename(doc)), overwrite = TRUE)
  }
}

message("\nSync complete.")
message("Latest:   ", latest_dir)
message("Version:  ", dated_dir)
