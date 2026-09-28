# Database schema — Rapid Adventure Game System (RAGS) file version 2.6.1

## Tables

- `CharacterActions`
- `CharacterProperties`
- `Characters`
- `GameData`
- `ItemActions`
- `ItemGroups`
- `ItemLayeredZoneLevels`
- `ItemProperties`
- `Items`
- `Media`
- `MediaGroups`
- `MediaLayeredImages`
- `Player`
- `PlayerActions`
- `PlayerProperties`
- `RoomActions`
- `RoomExits`
- `RoomProperties`
- `Rooms`
- `StatusBarItems`
- `Timer`
- `TimerActions`
- `TimerProperties`
- `VariableGroups`
- `VariableProperties`
- `Variables`

## Table `CharacterActions`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| Charname | nvarchar | 250 | yes |  | no | List |
| Data | ntext |  | yes |  | no | RagsAction |
## Table `CharacterProperties`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| Charname | nvarchar | 250 | yes |  | no | List |
| Name | nvarchar | 250 | yes |  | no | Unique |
| Value | ntext |  | yes |  | no |  |
## Table `Characters`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| Charname | nvarchar | 250 | yes |  | no | Unique |
| CharnameOverride | nvarchar | 250 | yes |  | no |  |
| CharGender | int |  | yes |  | no |  |
| CurrentRoom | nvarchar | 250 | yes |  | no |  |
| Description | ntext |  | yes |  | no |  |
| AllowInventoryInteraction | bit |  | yes |  | no |  |
| EnterFirstTime | bit |  | yes |  | no |  |
| LeaveFirstTime | bit |  | yes |  | no |  |
| CharPortrait | nvarchar | 255 | yes |  | no |  |
## Table `GameData`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| Title | nvarchar | 250 | yes |  | no |  |
| OpeningMessage | ntext |  | yes |  | no |  |
| HideMainPicDisplay | bit |  | yes |  | no |  |
| UseInlineImages | bit |  | yes |  | no |  |
| HidePortrait | bit |  | yes |  | no |  |
| AuthorName | nvarchar | 250 | yes |  | no |  |
| GameVersion | nvarchar | 50 | yes |  | no |  |
| GameInformation | ntext |  | yes |  | no |  |
| bgMusic | nvarchar | 250 | yes |  | no |  |
| RepeatbgMusic | bit |  | yes |  | no |  |
| PasswordProtected | bit |  | yes |  | no |  |
| GamePassword | nvarchar | 250 | yes |  | no |  |
| ObjectVersionNumber | nvarchar | 250 | yes |  | no |  |
| GameFont | nvarchar | 250 | yes |  | no |  |
| RoomGroups | ntext |  | yes |  | no |  |
| ClothingZoneLevels | ntext |  | yes |  | no |  |
| NotificationsOff | bit |  | no | 0 | no |  |
| SortOrderRoom | int |  | no | 0 | no |  |
| SortOrderCharacters | int |  | no | 0 | no |  |
| SortOrderInventory | int |  | no | 0 | no |  |
## Table `ItemActions`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| ItemID | nvarchar | 250 | yes |  | no | List |
| Data | ntext |  | yes |  | no | RagsAction |
## Table `ItemGroups`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| Name | nvarchar | 255 | yes |  | no | Unique |
| Parent | nvarchar | 255 | yes |  | no |  |
## Table `ItemLayeredZoneLevels`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| ItemID | nvarchar | 250 | yes |  | no | List |
| Data | nvarchar | 250 | yes |  | no |  |
## Table `ItemProperties`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| ItemID | nvarchar | 250 | yes |  | no | List |
| Name | nvarchar | 250 | yes |  | no | Unique |
| Value | ntext |  | yes |  | no |  |
## Table `Items`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| UniqueID | nvarchar | 250 | yes |  | no | Unique |
| Name | nvarchar | 250 | yes |  | no |  |
| Description | ntext |  | yes |  | no |  |
| SDesc | nvarchar | 250 | yes |  | no |  |
| Preposition | nvarchar | 250 | yes |  | no |  |
| LocationName | nvarchar | 250 | yes |  | no |  |
| LocationType | int |  | yes |  | no |  |
| Carryable | bit |  | yes |  | no |  |
| Wearable | bit |  | yes |  | no |  |
| Openable | bit |  | yes |  | no |  |
| Lockable | bit |  | yes |  | no |  |
| Enterable | bit |  | yes |  | no |  |
| Readable | bit |  | yes |  | no |  |
| Container | bit |  | yes |  | no |  |
| Weight | float |  | yes |  | no |  |
| Worn | bit |  | yes |  | no |  |
| Read | bit |  | yes |  | no |  |
| Locked | bit |  | yes |  | no |  |
| Open | bit |  | yes |  | no |  |
| Entered | bit |  | yes |  | no |  |
| Visible | bit |  | yes |  | no |  |
| EnterFirstTime | bit |  | yes |  | no |  |
| LeaveFirstTime | bit |  | yes |  | no |  |
| GroupName | nvarchar | 255 | yes |  | no |  |
| Important | bit |  | no | 0 | no |  |
## Table `Media`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| Name | nvarchar | 250 | yes |  | no | Unique |
| BackgroundColor | nvarchar | 250 | yes |  | no |  |
| TextColor | nvarchar | 250 | yes |  | no |  |
| TextFont | nvarchar | 250 | yes |  | no |  |
| ImageName | nvarchar | 250 | yes |  | no |  |
| UseEnhancedGraphics | bit |  | yes |  | no |  |
| NewImage | nvarchar | 250 | yes |  | no |  |
| Data | image |  | yes |  | no |  |
| GroupName | nvarchar | 255 | yes |  | no |  |
## Table `MediaGroups`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| Name | nvarchar | 255 | yes |  | no | Unique |
| Parent | nvarchar | 255 | yes |  | no |  |
## Table `MediaLayeredImages`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| MediaName | nvarchar | 250 | yes |  | no | List |
| Data | nvarchar | 250 | yes |  | no |  |
| Order | int |  | yes |  | no | Unique |
## Table `Player`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| Name | nvarchar | 250 | yes |  | no |  |
| Description | ntext |  | yes |  | no |  |
| StartingRoom | nvarchar | 250 | yes |  | no |  |
| CurrentRoom | nvarchar | 250 | yes |  | no |  |
| PlayerLayeredImage | nvarchar | 250 | yes |  | no |  |
| PlayerGender | int |  | yes |  | no |  |
| PromptForName | bit |  | yes |  | no |  |
| PromptForGender | bit |  | yes |  | no |  |
| PlayerPortrait | nvarchar | 250 | yes |  | no |  |
| EnforceWeight | bit |  | yes |  | no |  |
| WeightLimit | float |  | yes |  | no |  |
## Table `PlayerActions`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| Data | ntext |  | yes |  | no | RagsAction |
## Table `PlayerProperties`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| Name | nvarchar | 250 | yes |  | no | Unique |
| Value | ntext |  | yes |  | no |  |
## Table `RoomActions`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| RoomID | nvarchar | 250 | yes |  | no | List |
| Data | ntext |  | yes |  | no | RagsAction |
## Table `RoomExits`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| RoomID | nvarchar | 250 | yes |  | no | List |
| Direction | int |  | yes |  | no | Unique |
| Active | bit |  | yes |  | no |  |
| DestinationRoom | nvarchar | 250 | yes |  | no |  |
| PortalObjectName | nvarchar | 250 | yes |  | no |  |
## Table `RoomProperties`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| RoomID | nvarchar | 250 | yes |  | no | List |
| Name | nvarchar | 250 | yes |  | no | Unique |
| Value | ntext |  | yes |  | no |  |
## Table `Rooms`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| UniqueID | nvarchar | 250 | yes |  | no | Unique |
| Description | ntext |  | yes |  | no |  |
| SDesc | nvarchar | 250 | yes |  | no |  |
| Name | nvarchar | 250 | yes |  | no |  |
| RoomPic | nvarchar | 250 | yes |  | no |  |
| EnterFirstTime | bit |  | yes |  | no |  |
| LeaveFirstTime | bit |  | yes |  | no |  |
| Group | nvarchar | 250 | yes |  | no |  |
| LayeredRoomPic | nvarchar | 250 | yes |  | no |  |
## Table `StatusBarItems`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| Name | nvarchar | 255 | yes |  | no | Unique |
| Text | ntext |  | yes |  | no |  |
| Width | int |  | yes |  | no |  |
| Visible | bit |  | no | 1 | no |  |
## Table `Timer`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| Name | nvarchar | 250 | yes |  | no | Unique |
| TType | int |  | yes |  | no |  |
| Active | bit |  | yes |  | no |  |
| Restart | bit |  | yes |  | no |  |
| TurnNumber | int |  | yes |  | no |  |
| Length | int |  | yes |  | no |  |
| LiveTimer | bit |  | yes |  | no |  |
| TimerSeconds | int |  | yes |  | no |  |
## Table `TimerActions`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| Name | nvarchar | 250 | yes |  | no | List |
| Data | ntext |  | yes |  | no | RagsAction |
## Table `TimerProperties`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| TimerName | nvarchar | 250 | yes |  | no | List |
| Name | nvarchar | 250 | yes |  | no | Unique |
| Value | ntext |  | yes |  | no |  |
## Table `VariableGroups`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| Name | nvarchar | 255 | yes |  | no | Unique |
| Parent | nvarchar | 255 | yes |  | no |  |
## Table `VariableProperties`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| ID | int |  | no |  | yes | Exclude |
| VarName | nvarchar | 250 | yes |  | no | List |
| Name | nvarchar | 250 | yes |  | no | Unique |
| Value | ntext |  | yes |  | no |  |
## Table `Variables`

| Column | Data type | Max length (nvarchar) | Nullable | Default value | Auto-increment | Handling |
|---|---:|---:|---|---|---|---|
| VarName | nvarchar | 250 | yes |  | no | Unique |
| String | ntext |  | yes |  | no |  |
| NumType | float |  | yes |  | no |  |
| Min | nvarchar | 50 | yes |  | no |  |
| Max | nvarchar | 50 | yes |  | no |  |
| EnforceRestrictions | bit |  | yes |  | no |  |
| VarComment | ntext |  | yes |  | no |  |
| dtDateTime | datetime |  | yes |  | no |  |
| VarType | int |  | yes |  | no |  |
| VarArray | ntext |  | yes |  | no | Xml |
| GroupName | nvarchar | 255 | yes |  | no |  |
