# ABR bulk extract: DGR Item 1 vs Item 2 investigation

**Date:** 2026-07-09
**Question:** Does anything in the ABR bulk extract (data.gov.au "ABN Bulk Extract")
distinguish Item 1 DGRs (doing DGRs) from Item 2 DGRs (ancillary funds) — an
element, attribute, or code?

**Answer: No.** There is no item number, fund-type code, or any other marker
in the schema or the data. The only structural signal is *where* the DGR
element sits (entity-level vs named-fund), which does not map to Item 1/Item 2.

## Evidence

### 1. The XSD schema has no item field

`bulkextract.xsd` (downloaded from the data.gov.au dataset) defines the DGR
element in full as:

```xml
<xsd:complexType name="DGRType">
  <xsd:sequence minOccurs="0">
    <xsd:element name="NonIndividualName" type="NonIndividualNameType"/>
  </xsd:sequence>
  <xsd:attribute name="DGRStatusFromDate" use="required"/>
  <xsd:attribute name="status" type="xsd:string" use="optional"/>
</xsd:complexType>
```

That is the entire vocabulary: an endorsement-from date, an optional status,
and an optional fund name. No `item`, `type`, or fund-category attribute
exists anywhere in the schema. (The schema changelog notes "Apr 2015: Added
date of extract and main dgr" — no item marker was ever added.)

### 2. Only two flavours appear in the data

Scanned shard 1 of 20 (`20260708_Public01.xml`, 1,017,700 ABR records,
1,643 records with at least one DGR element, 1,757 DGR elements total):

| Flavour | Count | Meaning |
|---|---|---|
| Entity-level, self-closing | 1,351 | The entity itself is DGR-endorsed |
| Named fund | 406 | A fund the entity operates is endorsed |

**Entity-level** (always carries `status=`):

```xml
<DGR status="ACT" DGRStatusFromDate="20000701" />
```

**Named fund** (no `status` attribute; can repeat — one record had 3):

```xml
<DGR DGRStatusFromDate="20000701">
  <NonIndividualName type="DGR">
    <NonIndividualNameText>ST EXAMPLE SCHOOL BUILDING FUND</NonIndividualNameText>
  </NonIndividualName>
</DGR>
```

This entity-vs-fund distinction is **not** Item 1 vs Item 2: a school building
fund (named-fund flavour) is Item 1, while a private ancillary fund endorsed
in its own right (entity-level flavour) is Item 2. The flavour reflects
whether the endorsement attaches to the ABN or to a fund it operates.

### 3. The ABR API is the same

The pipeline's current DGR source (`SearchByABNv202001`, see
[R/ingest_abn_dgr.R](../R/ingest_abn_dgr.R)) returns `<dgrEndorsement>` /
`<dgrFund>` elements with an `<endorsedFrom>` date and entity/fund name — also
no item number. Item numbers are only published on the ABN Lookup *website*
per-ABN page and in the ATO's periodic DGR listings, not in any bulk or API
product.

## Provisional ancillary-fund flag

Since ancillary funds (Item 2) cannot be identified structurally, a
provisional flag via case-insensitive name matching on "ancillary" was
implemented in `build_charity_master`
([R/build_analytical.R](../R/build_analytical.R)) as
`is_ancillary_provisional`.

Shard-1 counts from the bulk extract (for context; the flag itself runs on
the ACNC register, not the bulk XML):

- 8 of 1,017,700 records had "ancillary" in the main entity name
  (e.g. "The Trustee for Knox Family Private Ancillary Fund"); 1 had it in a
  DGR fund name. Scaled across ~20 shards this is broadly consistent with the
  ~3,600 PAF+PuAF population in ATO Taxation Statistics, given many funds'
  legal names omit "ancillary" and trustee naming varies.

**Caveats:** name matching under-counts funds whose names omit "ancillary"
(permitted for PuAFs and older PAFs) and could in principle over-count
non-fund entities using the word, so the flag is provisional and should not
be used for headline statistics without validation against the ATO ancillary
fund counts.

---

## Update (2026-07-16): DGR Listing files DO carry item numbers

**Finding:** The ABN Lookup DGR Listing page
(https://abr.business.gov.au/Tools/DgrListing) publishes two downloadable
fixed-width plain-text files that **do** include the DGR item number:

1. **DGR endorsed entities** — column layout (1-based start positions):  
   ABN: 1, ABN status: 13, DGR status date: 24, State: 40, Postcode: 46,
   Entity name: 59, DGR item number: 260, DGR item type: 271.

2. **DGR funds, authorities and institutions** — column layout:  
   ABN: 1, ABN status: 13, DGR status date: 24, State: 45, Postcode: 51,
   DGR fund name: 64, Entity name: 289, DGR item number: 490.

Item 2 rows in the entities file are the ancillary funds (public and private),
giving a definitive structural classification.

**Pipeline change:** A new ingestion module `R/ingest_dgr_listing.R` now
downloads and parses both files. The resulting `dgr_listing.parquet` is
joined in `build_charity_master()` to produce:

- `dgr_item_number` — entity-level DGR item number (1, 2, or 4) from the
  entities file.
- `is_ancillary` — TRUE where `dgr_item_number == 2` (definitive flag).
- `has_item1_fund` — TRUE where the ABN also appears in the funds file (it
  operates a DGR-endorsed fund).

The provisional name-match flag (`is_ancillary_provisional`) is **retained**
for comparison and as a safety net for rows not matched in the listing
(e.g. charities with ACNC-withheld ABNs or very recently endorsed funds).

`build_dgr_gap_analysis()` now excludes charities where
`is_ancillary | is_ancillary_provisional`.

**Historical findings above are preserved** for the record — the ABR bulk
extract and ABR API genuinely do not expose item numbers; the DGR Listing
download files are a separate product.
