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
