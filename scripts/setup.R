#' One-time setup for the Unlock DGR pipeline.
#'
#' Run this once after cloning. It installs renv, restores package versions
#' from renv.lock (if present), and creates the data directories.
#'
#'   source("scripts/setup.R")

# 1. Install renv if not present
if (!requireNamespace("renv", quietly = TRUE)) {
  install.packages("renv")
}

# 2. Initialise or restore the project library
if (file.exists("renv.lock")) {
  renv::restore(prompt = FALSE)
} else {
  message("No renv.lock found. Initialising renv and capturing dependencies.")
  renv::init(bare = TRUE)
  pkgs <- c(
    "targets", "tarchetypes", "arrow", "duckdb", "dplyr", "readr",
    "janitor", "stringr", "lubridate", "httr2", "fs", "cli", "here",
    "readxl"
  )
  renv::install(pkgs, prompt = FALSE)
  renv::snapshot(prompt = FALSE)
}

# 3. Ensure data directories exist
dirs <- c("data/raw", "data/processed", "data/analytical")
for (d in dirs) {
  if (!dir.exists(d)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
}

message("Setup complete. Run scripts/build.R to build the pipeline.")
