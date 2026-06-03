# Experimental
# CopyMoveDeleteFeatures — v0.6

A [QField](https://qfield.org) plugin to delete, copy or move features between editable layers — filtered by expression or acting on an entire layer.

## What it does

- **Delete** features from a layer (filtered or entire layer) — fast C++ path, handles any size
- **Copy** features to another layer of the same geometry type — async, chunked, cancellable
- **Move** features (copy to destination + delete from source) — async, batched, cancellable
- **Filter** using a point-and-click field / operator / value builder, compound AND / OR conditions, or type a QGIS expression directly
- Loads matched features into a **reviewable checklist** — uncheck any to exclude before proceeding
- Live progress indicator with cancel button during Copy and Move
- Keeps the UI responsive throughout via chunked iteration and `Qt.callLater` yielding

Filters are saved per layer and restored automatically the next session.

> **Note — Feature IDs (FIDs):** Copied and moved features always receive new FIDs assigned by the destination layer. The original source FID is not preserved and no duplicate-check or upsert is performed. If you copy the same features twice, duplicates will be created.

## Installation

Copy the `CopyMoveDeleteFeatures` folder into your QField plugins directory:

| Platform | Directory |
|---|---|
| Android | `<device>/QField/plugins/` |
| Windows | `%APPDATA%\QField\plugins\` |
| Linux / macOS | `~/.local/share/QField/plugins/` |

Restart QField and enable the plugin from **Settings → Plugins**.

## Usage

1. Tap the plugin toolbar button to open the dialog
2. Choose **Delete**, **Move** or **Copy** at the top
3. Pick a **source layer** (and **destination layer** for Move/Copy — only layers with a matching geometry type are listed)
4. Choose **All** to act on every feature, or **Filter** to narrow by expression:
   - Pick a field, operator and value
   - Tap **Apply Filter** to set the expression, or **+ AND** / **+ OR** to append a second (or further) condition
   - Edit the Expression box directly for complex queries
   - Type at least 2 characters in the value box to see matching values as suggestions
5. Set the **Review subset** size (bottom of the scrollable area) — controls how many features are loaded into the checklist for review
6. Tap **Execute** — the plugin loads matching features into a checklist (with a spinner while loading)
7. In the feature list:
   - Use **Identify by** to choose which field labels each row
   - **Uncheck** any features you want to exclude from the operation
   - Use **All** / **None** to select or clear everything quickly
   - If the list is truncated, a second button appears to act on the **entire dataset** instead
8. Tap **Proceed** to run, or **Cancel** to return to the main dialog unchanged
9. For Copy and Move a live progress counter is shown — tap **Cancel operation** at any time to stop cleanly after the current batch

## Compound filters

Use **+ AND** / **+ OR** to chain multiple conditions:

| Step | Action | Expression |
|---|---|---|
| Field=name, Op==, Value=Tom | Apply Filter | `"name" = 'Tom'` |
| Field=species, Op=<>, Value=Cat | + AND | `("name" = 'Tom') AND "species" <> 'Cat'` |
| Field=age, Op=>, Value=5 | + AND | `("name" = 'Tom') AND "species" <> 'Cat' AND "age" > 5` |

The Expression box remains fully editable at any point.

## Filter operators

| Operator | Meaning |
|---|---|
| `=` | Equal to |
| `<>` | Not equal to |
| `> / <` | Greater / less than |
| `>= / <=` | Greater / less than or equal |
| `LIKE` | Pattern match — use `%` as wildcard |
| `IN` | Matches any value in a list |
| `NOT IN` | Matches none of a list |
| `IS NULL` | Field has no value |
| `IS NOT NULL` | Field has any value |

## Expression examples

| Expression | Meaning |
|---|---|
| `"name" = 'Tom'` | Exact text match |
| `"name" IN ('Tom', 'Alice')` | Any of a list |
| `"name" LIKE '%road%'` | Contains text |
| `"age" > 18` | Numeric comparison |
| `"create_date" < today()` | Before today (date field) |
| `"create_date" > '2024-06-01'` | After a specific date |
| `"edit_date" = '2026-04-18 20:18:52'` | Exact datetime match |
| `"notes" IS NULL` | Field is empty |

Tap **Help** in the dialog title bar for the full in-app reference.

## Date and datetime fields

- Values are auto-detected and wrapped in `to_date()` / `to_datetime()` automatically
- `today()` with `=` on a **datetime** field is rewritten to `date("field") = today()` so the time component is ignored — features on today's date match correctly
- `today()` with `<` or `>` is passed through as-is
- Typed value suggestions are formatted as `YYYY-MM-DD` or `YYYY-MM-DD HH:MM:SS` automatically

## Move / Copy behaviour

- Only layers with the **same geometry type** (point → point, line → line, polygon → polygon) appear in the destination list
- Fields are matched by name — fields that exist in both layers are copied; unmatched source fields are dropped (shown as `[X] dropped` in the dialog)
- **New FIDs are always assigned** by the destination layer — the source FID is not preserved
- No duplicate detection is performed — copying the same features twice creates duplicates

## Feature list / checklist

- Up to **N** matched features are loaded into the checklist (N = Review subset setting, default 500)
- If more than N features match, a warning is shown and a second **"from entire dataset"** button appears to act on the full matched set
- Use **Identify by** to switch the label field shown for each row
- The result toast shows the count of features acted on

## Async Copy / Move — progress and cancel

- **Copy** runs in chunks of 100 features; progress updates after each chunk; shows "Finishing up…" during the final commit
- **Move** runs in batches of 500 features (fewer commits = less overhead); progress updates after each batch
- Tap **Cancel operation** at any time — the current batch completes cleanly then stops; partial results are kept
- Very large datasets will be slow — use a filter to narrow scope where possible

## Performance notes

- The feature list loads in chunks of 25, yielding between each chunk to keep the UI responsive
- Value suggestions only trigger after 2+ characters, avoiding large layer scans while building a filter
- Field-type detection uses schema metadata only (no sample-value scan) to keep the UI fast

## Requirements

- QField 3.x
- Editable vector layers in your project

## Version history

| Version | Notes |
|---|---|
| **0.6** | Async Copy and Move with live progress, cancel button, and "Finishing up…" indicator. Improved handling of large datasets — Copy runs in chunks of 100, Move in batches of 500 to reduce commit overhead. Entire-dataset path is now also async and cancellable. Filter expressions saved and restored per layer including compound AND/OR expressions. Various UI and messaging improvements. |
| **0.5** | Initial public release — Delete, Copy, Move with expression filter builder, compound AND/OR filters, reviewable feature checklist, review subset size control, entire-dataset action. |

## Author

Tony Holmes — [github.com/TyHol](https://github.com/TyHol)
