# Experimental
# CopyMoveDeleteFeatures

A [QField](https://qfield.org) plugin to delete, copy or move features between editable layers — filtered by expression or acting on an entire layer.

## What it does

- **Delete** features from a layer (filtered or entire layer)
- **Copy** features to another layer of the same geometry type
- **Move** features (copy to destination + delete from source)
- **Filter** using a point-and-click field / operator / value builder, compound AND / OR conditions, or type a QGIS expression directly
- Loads matched features into a **reviewable checklist** — uncheck any you want to exclude before proceeding
- Shows a live **"X of Y features"** result after each operation
- Keeps the UI responsive during loading via chunked iteration

Filters are saved per layer and restored automatically the next session.


## Install:

<img width="372" height="378" alt="image" src="https://github.com/user-attachments/assets/9fc1868d-d2b4-40fb-bf8d-9b3953bd5e7e" />

## Usage

1. Tap the plugin toolbar button to open the dialog
2. Choose **Delete**, **Move** or **Copy** at the top
3. Pick a **source layer** (and **destination layer** for Move/Copy — only layers with a matching geometry type are listed)
4. Choose **All** to act on every feature, or **Filter** to narrow by expression:
   - Pick a field, operator and value
   - Tap **Apply Filter** to set the expression, or **+ AND** / **+ OR** to append a second (or further) condition
   - Edit the Expression box directly for complex queries
   - Type at least 2 characters in the value box to see matching values as suggestions
5. Tap **Execute** — the plugin loads matching features into a checklist (with a spinner while loading)
6. In the feature list:
   - Use **Identify by** to choose which field labels each row
   - **Uncheck** any features you want to exclude from the operation
   - Use **All** / **None** to select or clear everything quickly
7. Tap **Proceed** to run, or **Cancel** to return to the main dialog unchanged

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
- Fields are matched by name — fields that exist in both layers are copied; unmatched source fields are dropped (shown as **✘ dropped** in the dialog)

## Feature list / checklist

- Up to **500** matched features are loaded into the checklist
- If more than 500 match, a warning is shown and Proceed acts on the checked subset only — refine your filter to see more
- Use **Identify by** to switch the label field shown for each feature (e.g. switch from `name` to `species` to identify features more clearly)
- The result toast shows **"Deleted X of Y feature(s) from 'Layer'"** — X = checked and acted on, Y = total matched

## Performance notes

- The feature list loads in chunks of 25, yielding between each chunk to keep the UI responsive
- Value suggestions only trigger when you have typed at least 2 characters, avoiding large layer scans while you are building a filter
- Move / Copy of very large matched sets may cause a brief pause since all matched features must be iterated in sequence

## Requirements

- QField 3.x
- Editable vector layers in your project

## Author

Tony Holmes — [github.com/TyHol](https://github.com/TyHol)
