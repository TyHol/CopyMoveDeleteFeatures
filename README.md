# CopyMoveDeleteFeatures

A [QField](https://qfield.org) plugin to filter, select and copy, move or delete features between editable layers.

## What it does

- **Filter** features using an expression (field, operator, value) or type one directly
- **Select** which matched features to act on via a checklist
- **Delete** the selected features from the source layer
- **Copy** them to another layer with the same geometry type
- **Move** them (copy + delete from source)

Filters and label-field preferences are remembered per layer between sessions.

## Installation

Copy the `CopyMoveDeleteFeatures` folder into your QField plugins directory:

- **Android:** `<device>/QField/plugins/`
- **Desktop:** `~/.local/share/QField/plugins/` (Linux/Mac) or `%APPDATA%\QField\plugins\` (Windows)

Restart QField and enable the plugin from **Settings → Plugins**.

## Usage

1. Tap the plugin toolbar button to open the dialog
2. Choose **Delete**, **Copy to layer** or **Move to layer**
3. Select a source layer (and destination layer for copy/move)
4. Optionally set a filter — pick a field, operator and value, then tap **▶**
5. Tick the features you want to act on (or use **All** / **None**)
6. Tap **OK**, type `abc` to confirm

### Acting on the full matched set (no cap)

When an expression is set, a **Delete all ▶▶** / **Copy all ▶▶** / **Move all ▶▶** button appears.  
This bypasses the checklist and acts on every feature matching the expression — useful for large layers.

### Expression examples

| Expression | Meaning |
|---|---|
| `"name" = 'Tom'` | Exact text match |
| `"age" > 18` | Numeric comparison |
| `"status" IN ('A', 'B')` | Any of a list |
| `"name" LIKE '%road%'` | Contains text |
| `"edit_date" > '2024-01-01'` | After a date |
| `"notes" IS NULL` | Empty field |

Tap **?** inside the dialog for the full expression reference.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Max features (cap) | 500 | Limits checklist load — edit in dialog |
| Label field | (auto) | Field used as checklist row label — saved per layer |

## Requirements

- QField 3.x
- Editable vector layers in your project

## Author

tyhol — [github.com/TyHol](https://github.com/TyHol)
