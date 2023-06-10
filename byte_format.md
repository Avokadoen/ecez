# ECEZ byte format - .ezby

Ecez support a custom byte format called ezby (see issue [Implement serialize and deserialize #96](https://github.com/Avokadoen/ecez/issues/96)). This format define different [chunks](#chunk_sec) that contain structured bytes. This is inspired by the fantastic .vox format which is made by [ephtracy](https://github.com/ephtracy). 

## <a name="chunk_sec"></a>Chunks

// TODO: describe some restrictions on chunk order

This section contain each chunk defined by ezby and how they can be parsed.

### EZBY - File header metadata 

| <div style="width:155px">Data</div> | Bytes | <div style="width:300px">Description</div> |
|:------------------------------------|:-----:|:-------------------------------------------|
| "EZBY"                              | 4     | chunk identifier                           |
| *ezby major version*                | 1     | ezby major version of the current file     |
| *ezby minor version*                | 1     | ezby minor version of the current file     |
| *reserved*                          | 2     | reserved bytes                             |

### COMP - Metadata for each component type 

// TODO: should we include hashing algorithm used?

| <div style="width:155px">Data</div> | Bytes | <div style="width:300px">Description</div>             |
|:------------------------------------|:-----:|:------------------------------------------------------ |
| "COMP"                              | 4     | chunk identifier                                       |
| *number of<br>components*           | 4     | how many compoents that are stored in<br>the chunk (N) |
| *component_hash*                    | 8 * N | Component type hash identifier                         |
| *component_size*                    | 4 * N | Component byte size                                    |

### SHAR - SharedState chunk (TODO)

One SHAR(E) chunk contain one shareable entry. This include the byte hash and size of the shared state and the bytes for the state.

| <div style="width:155px">Data</div> |     Bytes        | <div style="width:200px">Description</div> |
|:------------------------------------|:----------------:|:-------------------------------------------|
| "SHAR"                              | 4                | chunk identifier                           |
| *RTTI hash*                         | 8                | Shared state type hash                     |
| *RTTI size*                         | 4                | Shared state type size                     |
| *Data bytes list*              | 1 * *RTTI size*  | Shared state data as bytes. This list<br>must follow the [alignment](#alignment_req) requirements |

### ARCH - All entities and component data for an archetype

// TODO: should not have type RTTI, but indices to the type RTTI. 
// This will introduce some minor complexity to ecez     
// TODO: Number of entities should be 32 since a entity is a 32b handle


| <div style="width:155px">Data</div>                                         |     Bytes        | <div style="width:300px">Description</div>             |
|:----------------------------------------------------------------------------|:----------------:|:-------------------------------------------------------|
| "ARCH"                                                                      | 4                | chunk identifier                                       |
| *number of component<br>types*                                              | 4                | How many lists of component bytes (N<sup>2</sup>)      |
| *number of entities*                                                        | 8                | How many entities in this archetype (N<sup>1</sup>)    |
| *N<sup>2</sup> type RTTI*                                                   | (8 + 4) * N<sup>2</sup>| First 8 bytes are the type hash, the subsequent 8 are the size |
| *N<sup>1</sup> entity map*                                                  | (4 + 4 + 8) * N<sup>1</sup>| First 4 bytes are the entity followed by 4 bytes of<br>padding and the subsequent 8 are the index in the<br>component list(s) |
| \|- *component byte list <br>\|&nbsp;&nbsp;M out of N<sup>2</sup>*          | 1 * size         | Component data as bytes. Byte count can be deduced from the<br>type RTTI. All list in a given chunk must be aligned to the<br>*biggest alignment*. This does not mean that each entry in the list<br>must be aligned, only the total list content of a individual list. |


## <a name="data_types"></a>Data types

TODO: some data types

