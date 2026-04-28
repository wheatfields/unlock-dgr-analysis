# `analysis/`

Finalised volunteer analyses that have been reviewed and committed.

**Workflow**: volunteers do exploratory work in their own SharePoint folders. When a piece of analysis is finalised — used in a deliverable, cited in the methodology, or supports a headline number — the volunteer sends the file to the repo owner. The repo owner reviews and commits it here.

**Filename convention**: `<volunteer_initials>_<topic>_<yyyymmdd>.{R,qmd,Rmd}`

**Header convention**: every file starts with a comment block stating:
- Author and date
- What it does (one sentence)
- Which analytical Parquet files it depends on
- What snapshot date of those files was used

This way each committed analysis is reproducible against a known data snapshot.
