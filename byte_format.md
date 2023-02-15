# ECEZ byte format - .ezby

Ecez support a custom byte format called ezby (see issue [Implement serialize and deserialize #96](https://github.com/Avokadoen/ecez/issues/96)). This format define different [chunks](#chunk_sec) that contain structured bytes. This is inspired by the fantastic .vox format which is made by [ephtracy](https://github.com/ephtracy). 

## <a name="chunk_sec"></a>Chunks

// TODO: describe some restrictions on chunk order

This section contain each chunk defined by ezby and how they can be parsed.

### EZBY - File header metadata 

| <div style="width:155px">Data</div> | Bytes | <div style="width:300px">Description</div>                    |
|:------------------------------------|:-----:|:--------------------------------------------------------------|
| "EZBY"                              | 4     | chunk identifier                                              |
| *ezby major version*                | 1     | ezby major version of the current file                        |
| *ezby minor version*                | 1     | ezby minor version of the current file                        |
| *ezby patch version*                | 1     | ezby patch version of the current file                        |
| *reserved_1*                        | 1     | reserved byte                                                 |
| *EREF chunks*                       | 2     | how many EREF chunks one EREF<br>maps to one ezez instance    |
| *COMP chunks*                       | 2     | how many COMP chunks                                          |
| *ARCH chunks*                       | 2     | how many ARCH chunks                                          |
| *reserved_2*                        | 2     | reserved 2 bytes                                              |

### COMP - Metadata for each component type 

// TODO: is this chunk useless for ezez (components are mostly compile time, but maybe we can use this in the build script to generate components?)

| <div style="width:155px">Data</div> | Bytes | <div style="width:300px">Description</div>             |
|:------------------------------------|:-----:|:------------------------------------------------------ |
| "COMP"                              | 4     | chunk identifier                                       |
| *number of<br>components*           | 4     | how many compoents that are stored in<br>the chunk (N) |
| *component_hash*                    | 8 * N | Component type hash identifier                         |
| *component_size*                    | 8 * N | Component byte size                                    |


### ARCH - All entities and component data for an archetype

| <div style="width:155px">Data</div>                                         |     Bytes        | <div style="width:300px">Description</div>             |
|:----------------------------------------------------------------------------|:----------------:|:-------------------------------------------------------|
| "ARCH"                                                                      | 4                | chunk identifier                                       |
| *number of entities*                                                        | 4                | How many entities in this archetype (N<sup>1</sup>) |
| *N<sup>1</sup> entities*                                                    | 4 * N<sup>1</sup>| List of entities                                       |
| *number of componet<br>byte data lists*                                     | 4                | How many lists of component bytes (N<sup>2</sup>)   |
| \|- *component byte list <br>\|&nbsp;&nbsp;**size** M out of N<sup>2</sup>* | 4                | How many bytes are in the subsequent<br>list (M)      |
| \|- *component byte list <br>\|&nbsp;&nbsp;M out of N<sup>2</sup>*          | 1 * M            | Component data as bytes                                |

## <a name="data_types"></a>Data types

TODO: some data types
