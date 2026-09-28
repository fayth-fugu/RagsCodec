# Data mapping between RAGS and flat files

## General

- Tables, columns, and special handling rules are defined in the [schema documentation](./rags-schema-v2.6.1.md)
- A [template file](../deps/template.rag) serves as the base file for serialization operations
  - This is essentially a blank game created via RAGS Designer
- A single RAGS file is deserialized into multiple YAML files
  - YAML is chosen over JSON due to native support for multi-line string literals
  - Refer to the [rules](#yaml-serializationdeserialization-rules) below for mapping between RAGS and YAML types
  - Refer to the [conventions](#table-serializationdeserialization-conventions) below for how each RAGS table is deserialized

## Special handling instructions

- Columns tagged with the `Exclude` handling instruction are **excluded from deserialization** and ignored during serialization
  - These columns are all auto-increment columns (currently) and do not need to be manually set
- Columns tagged with the `List` handling instruction will group rows containing the same value and serve as the key for a **YAML sequence or mapping**
  - If the table has only **one** other non-`Exclude` column (in addition to the `List` column), a *YAML sequence* is generated
  - If the table has **more than one** other non-`Exclude` column (in addition to the `List` column), a *YAML mapping* is generated (a `Unique` column needs to exist to serve as the key)
  - **Maximum one** `List` **column per table**
- Columns tagged with the `Unique` handling instruction are expected to **contain only distinct values**
  - This is *soft-validated* during deserialization — a warning is shown if duplicate values are detected
    - Tables are sorted before deserializing (refer to individual tables below for sorting conditions) and only the *first duplicate entry* is read
    - An optional parameter is available to throw an error and abort deserialization if duplicates are present
  - If there are `List` and/or other `Unique` columns present, only the entire group needs to be distinct
- Columns tagged with the `Xml` handling instruction may contain XML data
  - Data in these columns are *pretty-printed* during deserialization, then *linearized* during serialization
  - If pretty-printing/linearizing fails, then the *raw value* is read/written
- Columns tagged with the `RagsAction` handling instruction contain encoded data which needs to be deserialized and serialized in a certain format — refer to the [format specification](#rags-action-format-specification) below

## RAGS Action format specification

- *Base64-encoded binary stream* with the following structure:
  - **4 bytes of padding** at stream start
    - These 4 bytes store the size of the subsequent GZip stream
    - This information is unnecessary and can be safely **discarded** during deserialization
      - **Note:** RAGS Designer requires this information for its internal GZip decompression — the default value of `16 MiB` can be optionally increased to allow for massively complex RAGS Actions
    - When serializing, the padding value is set to a *default static value* (`FF FF FF 00` — `16777215` in little-endian unsigned int, sufficient for a `16 MiB` GZip stream)
      - An optional parameter is available to set a *custom padding value* (maximum value limited to `FF FF FF 7F` — `2147483647` in little-endian unsigned int, indicating a `2 GiB` GZip stream)
      - *Lowering* the padding value below the default is *not supported*
  - All *subsequent bytes* after the padding represent a **standard GZip stream** containing an **XML** snippet (with no XML declaration)
    - The GZip stream may be compressed with *any compression level*, but **Default** compression levels are recommended when serializing
  - The XML snippet is usually *stored linearized* and is *pretty-printed during deserialization*

## YAML serialization/deserialization rules

- All YAML nodes are *explicitly tagged* with their data type during deserialization to enforce strict typing
  - This restriction is not imposed during serialization
- SQL CE 3.5 data types used by RAGS and their corresponding YAML mapping:
  - `int` => `!!int`
  - `nvarchar` => `!!str`
    - The string value is output as a quoted string
    - During serialization, input strings which *exceed the defined max length* indicated in the RAGS schema are *truncated with a warning*
  - `ntext` => `!!str |`
    - `ntext` fields usually contain *multi-line free text or XML* and will use the *literal block indicator* `|`
  - `bit` => `!!bool`
    - `0` and null values are mapped to `false`, while `1` is mapped to `true`
  - `float` => `!!float`
  - `image` => `!!binary`
    - The binary stream is *Base64-encoded* during deserialization
  - `datetime` => `!!timestamp`
    - `datetime` values are extracted as `ISO 8601 strings`
  - `null` values for any data type (except `bit`) => `!!null`

## Table serialization/deserialization conventions

### Notes

- `{COLUMNNAME}` placeholders in YAML samples below are replaced with the actual column values during deserialization
- `RagsAction`-containing tables (except for `PlayerActions`) are deserialized into individual subfolders containing multiple YAML files
  - These tables usually contain lots of XML data, and deserializing into a single YAML file would result in too-large YAML files — bad for maintainability and version control
  - These YAML files are named using the values from the `List` column in each table
  - `PlayerActions` is essentially `CharacterActions` for a single character, hence it is kept as a single file
- `GUID` filename generation logic:
  - `CharacterActions`, `Media` and `TimerActions` tables allow free text in their `List` column — this is a potential source of issues when deserializing into individual files, as the column's value may not be a valid filename
  - To mitigate this issue, the column's value is first converted into a `GUID` before being used as a filename
  - The column's value is first MD5-hashed, then the result of the hash is used to generate a `GUID`

### Individual table handling

- `CharacterActions`
  - Deserialized into a subfolder — `CharacterActions/`
  - All distinct values are retrieved from the `Charname` column
  - Filename generation:
    - A YAML file is created for each distinct `Charname` value with the naming convention `{GUID}.yaml`
      - The `GUID` value is converted from `Charname` as described above
      - The `Charname` value is written to the YAML file as the first node
  - Table retrieval:
    - Table is sorted first by `Charname` ascending, then by `ID` ascending
    - `Data` rows for each `Charname` are extracted using `RagsAction`-specific deserialization
  - Structure of each `{GUID}.yaml` file:

    ```yaml
    {Charname}:
      - {Data}
      - {Data}
      - ...
    ```

- `CharacterProperties`
  - Deserialized into a single file — `CharacterProperties.yaml`
  - TODO
- `Characters`
  - Deserialized into a single file — `Characters.yaml`
  - TODO
- `GameData`
  - Deserialized into a single file — `GameData.yaml`
  - TODO
- `ItemActions`
  - Deserialized into a subfolder — `ItemActions/`
  - TODO
- `ItemGroups`
  - Deserialized into a single file — `ItemGroups.yaml`
  - TODO
- `ItemLayeredZoneLevels`
  - Deserialized into a single file — `ItemLayeredZoneLevels.yaml`
  - TODO
- `ItemProperties`
  - Deserialized into a single file — `ItemProperties.yaml`
  - TODO
- `Items`
  - Deserialized into a single file — `Items.yaml`
  - TODO
- `Media`
  - Deserialized into a subfolder — `Media/`
  - TODO
- `MediaGroups`
  - Deserialized into a single file — `MediaGroups.yaml`
  - TODO
- `MediaLayeredImages`
  - Deserialized into a single file — `MediaLayeredImages.yaml`
  - TODO
- `Player`
  - Deserialized into a single file — `Player.yaml`
  - TODO
- `PlayerActions`
  - Deserialized into a single file — `PlayerActions.yaml`
  - TODO
- `PlayerProperties`
  - Deserialized into a single file — `PlayerProperties.yaml`
  - TODO
- `RoomActions`
  - Deserialized into a subfolder — `RoomActions/`
  - TODO
- `RoomExits`
  - Deserialized into a single file — `RoomExits.yaml`
  - TODO
- `RoomProperties`
  - Deserialized into a single file — `RoomProperties.yaml`
  - TODO
- `Rooms`
  - Deserialized into a single file — `Rooms.yaml`
  - TODO
- `StatusBarItems`
  - Deserialized into a single file — `StatusBarItems.yaml`
  - TODO
- `Timer`
  - Deserialized into a single file — `Timer.yaml`
  - TODO
- `TimerActions`
  - Deserialized into a subfolder — `TimerActions/`
  - TODO
- `TimerProperties`
  - Deserialized into a single file — `TimerProperties.yaml`
  - TODO
- `VariableGroups`
  - Deserialized into a single file — `VariableGroups.yaml`
  - TODO
- `VariableProperties`
  - Deserialized into a single file — `VariableProperties.yaml`
  - TODO
- `Variables`
  - Deserialized into a single file — `Variables.yaml`
  - TODO
