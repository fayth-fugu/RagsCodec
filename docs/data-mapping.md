# Data mapping between RAGS and flat files

## General

- Tables, columns, and special handling rules are defined in the [schema documentation](./rags-schema-v2.6.1.md)
- A [template file](../deps/template.rag) serves as the base file for compression operations
  - This is essentially a blank game created via RAGS Designer
- A single RAGS file is expanded into multiple YAML files
  - YAML is chosen over JSON due to native support for multi-line string literals
  - Refer to the [rules](#yaml-compressionexpansion-rules) below for mapping between RAGS and YAML types
  - Refer to the [conventions](#table-compressionexpansion-conventions) below for how each RAGS table is expanded

## Special handling instructions

- Columns tagged with the `Exclude` handling instruction are **excluded from expansion** and ignored during compression
- Columns tagged with the `List` handling instruction will group rows containing the same value and serve as the key for a **YAML sequence or mapping** (for *single-file expansions*) or as the **filename** (for *subfolder expansions*)
  - If the table has only **one** other non-`Exclude` column (in addition to the `List` column), a *YAML sequence* is generated
  - If the table has **more than one** other non-`Exclude` column (in addition to the `List` column), a *YAML mapping* is generated
    - A `Unique` column needs to exist to serve as the key
  - **Maximum one** `List` **column per table**
- Columns tagged with the `Unique` handling instruction are expected to **contain only distinct values**
  - This is *soft-validated* during expansion — a warning is shown if duplicate values are detected
    - Tables are sorted before expansion and only the *first duplicate entry* is read
      - Refer to individual tables below for sorting conditions
    - An optional parameter is available to throw an error and abort expansion if duplicates are present
  - If there are `List` and/or other `Unique` columns present, the columns are grouped together for distinctiveness checks
- Columns tagged with the `Xml` handling instruction may contain XML data (with no XML declaration)
  - Data in these columns are *pretty-printed* during expansion, then *linearized* during compression
  - If pretty-printing/linearizing fails, then the *raw value* is read/written
- Columns tagged with the `RagsAction` handling instruction contain encoded data which needs a custom compressor/expander
  - Refer to the [format specification](#rags-action-format-specification) below

## RAGS Action format specification

- *Base64-encoded binary stream* with the following structure:
  - **4 bytes of padding** at stream start
    - These 4 bytes store the size of the subsequent GZip stream
    - This information is unnecessary and can be safely **discarded** during expansion
      - **Note:** RAGS Designer requires this information for its internal GZip decompression — the default value of `16 MiB` can be optionally increased to allow for massively complex RAGS Actions
    - When compressing, the padding value is set to a *default static value* (`FF FF FF 00` — `16777215` in little-endian unsigned int, sufficient for a `16 MiB` GZip stream)
      - An optional parameter is available to set a *custom padding value* (maximum value limited to `FF FF FF 7F` — `2147483647` in little-endian unsigned int, indicating a `2 GiB` GZip stream)
      - *Lowering* the padding value below the default is *not supported*
  - All *subsequent bytes* after the padding represent a **standard GZip stream** containing an **XML** snippet (with no XML declaration)
    - The GZip stream may be compressed with *any compression level*, but **Default** compression levels are recommended when compressing
  - The XML snippet is usually *stored linearized* and is *pretty-printed during expansion*

## YAML compression/expansion rules

- SQL CE 3.5 data types used by RAGS and their corresponding YAML mapping:
  - `int` => `!!int`
  - `nvarchar` => `!!str`
    - During compression, input strings which *exceed the defined max length* indicated in the RAGS schema are *truncated with a warning*
  - `ntext` => `!!str`
    - `ntext` fields contain *multi-line free text or XML*
  - `bit` => `!!bool`
    - `0` and null values are mapped to `false`, while `1` is mapped to `true`
  - `float` => `!!float`
  - `image` => `!!binary`
    - The binary stream is *Base64-encoded* during expansion
  - `datetime` => `!!timestamp`
    - `datetime` values are extracted as `ISO 8601 strings`
  - `null` values for any data type (except `bit`) => `!!null`

## Table compression/expansion conventions

### Notes

- `{COLUMNNAME}` placeholders in YAML samples below are replaced with the actual column values during expansion
- `RagsAction`-containing tables (except for `PlayerActions`) are expanded into individual subfolders containing multiple YAML files
  - These YAML files are named using the values from the `List` column in each table
- `GUID` (Globally Unique Identifier) filename generation logic:
  - `CharacterActions`, `Media` and `TimerActions` tables with `List` columns will have their column names converted to a `GUID` before being used as a filename
  - The column value is UTF-8 encoded, and the MD5 hash (a 16-byte digest) of the encoded bytes is used directly to construct a `GUID`, whose lowercase, dash-separated (`D` format) string form is used as the filename

### Individual table handling

- `CharacterActions`
  - Expanded into a subfolder — `CharacterActions/`
  - `List`-column handling: A YAML file is created for each distinct `Charname` value with the naming convention `{GUID}.yaml` (in lowercase)
    - The `GUID` value is converted from `Charname` as described above
  - Table is sorted first by `Charname` ascending, then by `ID` ascending
  - `RagsAction`-column handling: All `Data` rows for each `Charname` are extracted using `RagsAction` expansion
  - Sample structure of each `{GUID}.yaml` file:
    ```yaml
    Charname: {Charname}
    Data:
      - |
        {Data}
      - |
        {Data}
      - |
        {Data}
    ```
- `CharacterProperties`
  - Expanded into a single file — `CharacterProperties.yaml`
  - TODO
- `Characters`
  - Expanded into a single file — `Characters.yaml`
  - TODO
- `GameData`
  - Expanded into a single file — `GameData.yaml`
  - TODO
- `ItemActions`
  - Expanded into a subfolder — `ItemActions/`
  - TODO
- `ItemGroups`
  - Expanded into a single file — `ItemGroups.yaml`
  - TODO
- `ItemLayeredZoneLevels`
  - Expanded into a single file — `ItemLayeredZoneLevels.yaml`
  - TODO
- `ItemProperties`
  - Expanded into a single file — `ItemProperties.yaml`
  - TODO
- `Items`
  - Expanded into a single file — `Items.yaml`
  - TODO
- `Media`
  - Expanded into a subfolder — `Media/`
  - TODO
- `MediaGroups`
  - Expanded into a single file — `MediaGroups.yaml`
  - TODO
- `MediaLayeredImages`
  - Expanded into a single file — `MediaLayeredImages.yaml`
  - TODO
- `Player`
  - Expanded into a single file — `Player.yaml`
  - TODO
- `PlayerActions`
  - Expanded into a single file — `PlayerActions.yaml`
  - TODO
- `PlayerProperties`
  - Expanded into a single file — `PlayerProperties.yaml`
  - TODO
- `RoomActions`
  - Expanded into a subfolder — `RoomActions/`
  - TODO
- `RoomExits`
  - Expanded into a single file — `RoomExits.yaml`
  - TODO
- `RoomProperties`
  - Expanded into a single file — `RoomProperties.yaml`
  - TODO
- `Rooms`
  - Expanded into a single file — `Rooms.yaml`
  - TODO
- `StatusBarItems`
  - Expanded into a single file — `StatusBarItems.yaml`
  - TODO
- `Timer`
  - Expanded into a single file — `Timer.yaml`
  - TODO
- `TimerActions`
  - Expanded into a subfolder — `TimerActions/`
  - TODO
- `TimerProperties`
  - Expanded into a single file — `TimerProperties.yaml`
  - TODO
- `VariableGroups`
  - Expanded into a single file — `VariableGroups.yaml`
  - TODO
- `VariableProperties`
  - Expanded into a single file — `VariableProperties.yaml`
  - TODO
- `Variables`
  - Expanded into a single file — `Variables.yaml`
  - TODO
