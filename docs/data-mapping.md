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
- Columns tagged with the `List` handling instruction will group rows containing the same value and serve as the main entry for a **YAML sequence** (for *single-file expansions*) or as the **filename** (for *subfolder expansions*)
  - **Maximum one** `List` **column per table**
- Columns tagged with the `Unique` handling instruction are expected to **contain only distinct values**
  - This is *soft-validated* during expansion — a warning is shown if duplicate values are detected
    - Tables are sorted before expansion and only the *first duplicate entry* is read
      - Refer to individual tables below for sorting conditions
  - **Maximum one** `Unique` **column per table**
- Columns tagged with the `Xml` handling instruction may contain XML data (with no XML declaration)
  - Data in these columns are *pretty-printed* during expansion, then *linearized* during compression
  - If pretty-printing/linearizing fails, then the *raw value* is read/written
- Columns tagged with the `RagsAction` handling instruction contain encoded data that needs a custom compressor/expander
  - Refer to the [format specification](#rags-action-format-specification) below

## RAGS Action format specification

- *Base64-encoded binary stream* with the following structure:
  - **4 bytes of padding** at stream start
    - These 4 bytes store the *decompressed size* of the subsequent **GZip stream**
      - The value is stored in **little-endian unsigned int**, e.g. `FF FF FF 00` for `16777215` bytes
      - This info is *discarded* during expansion
    - **RAGS Designer requires** this info for its internal GZip decompression
      - The value is detected from the **input XML size** during *recompression*
      - An additional `1 MiB` (`1048576` bytes) will be added to the detected size, to serve as a buffer
  - All *subsequent bytes* after the padding represent a **standard GZip stream** containing an **XML** snippet (with no XML declaration)
    - The GZip stream may be compressed with *any compression level*, but **Default** compression level is recommended when compressing
  - The XML snippet is usually *stored linearized* and is *pretty-printed during expansion*

## YAML compression/expansion rules

- SQL CE 3.5 data types used by RAGS and their corresponding YAML mapping:
  - `int` => `!!int`
  - `nvarchar` => `!!str`
    - During compression, input strings which *exceed the defined max length* indicated in the RAGS schema are *truncated with a warning*
  - `ntext` => `!!str`
    - `ntext` fields contain *multi-line free text or XML*
  - `bit` => `!!bool`
    - `0` and `null` values are mapped to `false`, while `1` is mapped to `true`
  - `float` => `!!float`
  - `image` => `!!binary`
    - The binary stream is *Base64-encoded* during expansion
  - `datetime` => `!!timestamp`
    - `datetime` values are extracted as *ISO 8601 strings*
  - `null` values for any data type (except `bit`) => `!!null`

## Table compression/expansion conventions

### Notes

- `{ColumnName}` placeholders in YAML samples below are replaced with the actual column values during expansion
- `RagsAction`-containing tables (except for `PlayerActions`) are expanded into individual subfolders containing multiple YAML files
  - These YAML files are named using the values from the `List` column in each table
- `GUID` (Globally Unique Identifier) filename generation logic:
  - `CharacterActions`, `Media`, and `TimerActions` tables with `List` columns will have their column values converted to a `GUID` before being used as a filename
  - The column value is UTF-8 encoded, and the MD5 hash (a 16-byte digest) of the encoded bytes is used directly to construct a `GUID`, whose lowercase, dash-separated (`D` format) string form is used as the filename

### Individual table handling

- `CharacterActions`
  - Expanded into a subfolder — `CharacterActions/`
  - `List`-column handling: A YAML file is created for each distinct `Charname` value with the naming convention `{GUID}.yaml`
    - The `GUID` value is derived from `Charname` as described above
  - Table is sorted first by `Charname` ascending, then by `ID` ascending
  - `RagsAction`-column handling: All `Data` rows for each `Charname` are extracted using `RagsAction` expansion
  - Sample structure of each `{GUID}.yaml` file:
    ```yaml
    Charname: {Charname}
    Data:
      - {Data}
      - {Data}
      - {Data}
    ```
- `CharacterProperties`
  - Expanded into a single file — `CharacterProperties.yaml`
  - `List`-column handling: Each distinct `Charname` value starts a new entry in the top-level YAML sequence
  - Table is sorted first by `Charname` ascending, then by `Name` ascending, then by `ID` ascending
  - `Unique`-column handling: If multiple identical `Name`s exist for the same `Charname` value, then only the `Value` of the first row will be read
    - First-row ordering will be determined by the sorting rules of the table
    - A warning containing the values of subsequent ignored duplicate rows will be shown
  - Sample structure of a `CharacterProperties.yaml` file:
    ```yaml
    CharacterProperties:
      - Charname: {Charname}
        Name:
          - Name: {Name}
            Value: {Value}
          - Name: {Name}
            Value: {Value}
          - Name: {Name}
            Value: {Value}
      - Charname: {Charname}
        Name:
          - Name: {Name}
            Value: {Value}
          - Name: {Name}
            Value: {Value}
          - Name: {Name}
            Value: {Value}
      - Charname: {Charname}
        Name:
          - Name: {Name}
            Value: {Value}
          - Name: {Name}
            Value: {Value}
          - Name: {Name}
            Value: {Value}
    ```
- `Characters`
  - Expanded into a single file — `Characters.yaml`
  - Table is sorted by `Charname` ascending
  - `Unique`-column handling: If multiple identical `Charname`s exist, then only the first row's column values will be read
    - First-row ordering will be determined by the sorting rules of the table
    - A warning containing the values of subsequent ignored duplicate rows will be shown
    - RAGS Designer **does not support** characters whose names differ only in *capitalization* — this particular unique check is case-insensitive
  - Sample structure of a `Characters.yaml` file:
    ```yaml
    Characters:
      - Charname: {Charname}
        CharnameOverride: {CharnameOverride}
        CharGender: {CharGender}
        CurrentRoom: {CurrentRoom}
        Description: {Description}
        AllowInventoryInteraction: {AllowInventoryInteraction}
        EnterFirstTime: {EnterFirstTime}
        LeaveFirstTime: {LeaveFirstTime}
        CharPortrait: {CharPortrait}
      - Charname: {Charname}
        CharnameOverride: {CharnameOverride}
        CharGender: {CharGender}
        CurrentRoom: {CurrentRoom}
        Description: {Description}
        AllowInventoryInteraction: {AllowInventoryInteraction}
        EnterFirstTime: {EnterFirstTime}
        LeaveFirstTime: {LeaveFirstTime}
        CharPortrait: {CharPortrait}
      - Charname: {Charname}
        CharnameOverride: {CharnameOverride}
        CharGender: {CharGender}
        CurrentRoom: {CurrentRoom}
        Description: {Description}
        AllowInventoryInteraction: {AllowInventoryInteraction}
        EnterFirstTime: {EnterFirstTime}
        LeaveFirstTime: {LeaveFirstTime}
        CharPortrait: {CharPortrait}
    ```
- `GameData`
  - Expanded into a single file — `GameData.yaml`
  - This table should only have **a single row** — if multiple rows exist, only the first row's column values will be read
  - Sample structure of a `GameData.yaml` file:
    ```yaml
    Title: {Title}
    OpeningMessage: {OpeningMessage}
    HideMainPicDisplay: {HideMainPicDisplay}
    UseInlineImages: {UseInlineImages}
    HidePortrait: {HidePortrait}
    AuthorName: {AuthorName}
    GameVersion: {GameVersion}
    GameInformation: {GameInformation}
    bgMusic: {bgMusic}
    RepeatbgMusic: {RepeatbgMusic}
    PasswordProtected: {PasswordProtected}
    GamePassword: {GamePassword}
    ObjectVersionNumber: {ObjectVersionNumber}
    GameFont: {GameFont}
    RoomGroups: {RoomGroups}
    ClothingZoneLevels: {ClothingZoneLevels}
    NotificationsOff: {NotificationsOff}
    SortOrderRoom: {SortOrderRoom}
    SortOrderCharacters: {SortOrderCharacters}
    SortOrderInventory: {SortOrderInventory}
    ```
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
