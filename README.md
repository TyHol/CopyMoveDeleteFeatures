# CopyMoveDeleteFeatures

A [QField](https://qfield.org) plugin to delete, copy or move features between editable layers — filtered by expression or acting on an entire layer.

## What it does

- **Delete** features from a layer (filtered or all)
- **Copy** features to another layer of the same geometry type
- **Move** features (copy to destination + delete from source)
- **Filter** using a point-and-click field/operator/value builder, or type a QGIS expression directly
- Shows a **feature count** before anything is changed, with a Proceed / Cancel step
- Always acts on **all** features matching the expression — there is no per-feature tick list

Filters are saved per layer and restored automatically the next session.

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
   - Pick a field, operator and value, then tap **Apply Filter**
   - The expression box is filled automatically — edit it directly for complex queries
   - Typing in the value box shows matching values from the layer as a suggestion list
5. Tap **Execute**
6. Review the feature count in the confirmation screen — tap **Proceed** to run or **Cancel** to go back and adjust

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

Tap **Help** in the dialog title bar for the full expression reference.

## Date and datetime fields

- Values are auto-detected as date or datetime and wrapped in `to_date()` / `to_datetime()` automatically
- `today()` with `=` on a **datetime** field is rewritten to `date("field") = today()` so the time component is ignored — features on today's date are matched correctly
- `today()` with `<` or `>` is passed through as-is
- Type suggestions from the layer are formatted as `YYYY-MM-DD` or `YYYY-MM-DD HH:MM:SS` automatically

## Move / Copy behaviour

- Only layers with the **same geometry type** (point → point, line → line, polygon → polygon) appear in the destination list — mismatches are excluded automatically
- Fields are matched by name — fields that exist in both layers are copied; source fields with no matching name in the destination are dropped (shown in the dialog below the destination selector)

## Performance note

Counting and executing may be slow on layers with very large numbers of features. Use a filter to narrow the scope where possible.

## Requirements

- QField 3.x
- Editable vector layers in your project

## Author

Tony Holmes — [github.com/TyHol](https://github.com/TyHol)
