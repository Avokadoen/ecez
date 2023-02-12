# ECEZ byte formar - .ezby

Ecez support a custom byte format called ezby (see issue [Implement serialize and deserialize #96](https://github.com/Avokadoen/ecez/issues/96)). This format define different [chunks](#chunk_sec) that contain structured bytes. This is inspired by the fantastic .vox format which is made by [ephtracy](https://github.com/ephtracy). 

## <a name="chunk_sec"></a>Chunks

This section contain each chunk defined by ezby and how they can be parsed.

### EZBY - File header metadata 

| <div style="width:155px">Data</div> | Bytes | <div style="width:200px">Description</div>                    |
|:------------------------------------|:-----:|:--------------------------------------------------------------|
| "EZBY"                              | 4     | chunk identifier                                              |
| *file size*                         | 4     | the size of the file                                          |
| *EREF chunks*                       | 2     | how many EREF chunks<br>one EREF maps to one<br>ecez instance |
| *COMP chunks*                       | 2     | how many COMP chunks                                          |
| *ARCH chunks*                       | 2     | how many ARCH chunks                                          |

### EREF - Contain entity references

The reference can be used to get the component data from a given entity. TODO: explain mapping of entity to entity reference

| <div style="width:155px">Data</div> | Bytes | <div style="width:200px">Description</div>                                     |
|:------------------------------------|:-----:|:-------------------------------------------------------------------------------|
| "EREF"                              | 4     | chunk identifier                                                               |
| *number of references*              | 4     | how many references<br>the chunk contain (N)                                   |
| *N entity references*               | N * 2 | references that can<br>be used to look up <br>components for a given<br>entity |

### COMP - Metadata for each component type 

// TODO: is this chunk useless for ecez (components are mostly compile time, but maybe we can use this in the build script to generate components?)

| <div style="width:155px">Data</div> | Bytes | <div style="width:200px">Description</div>             |
|:------------------------------------|:-----:|:------------------------------------------------------ |
| "COMP"                              | 4     | chunk identifier                                       |
| *number of<br>components*           | 4     | how many compoents that<br>are stored in the chunk (N) |
| *Component:*                        | 8 * N | Component RTTI (Run-Time<br>Type Info) for a component |
| \|- *type hash*                     | 4     | Component type hash<br>identifier                      |
| \|- *byte size*                     | 4     | Component byte size                                    |


### ARCH - All entities and component data for an archetype

| <div style="width:155px">Data</div>                                         |     Bytes        | <div style="width:200px">Description</div>             |
|:----------------------------------------------------------------------------|:----------------:|:-------------------------------------------------------|
| "ARCH"                                                                      | 4                | chunk identifier                                       |
| *number of entities*                                                        | 4                | How many entities in this<br>archetype (N<sup>1</sup>) |
| *N<sup>1</sup> entities*                                                    | 4 * N<sup>1</sup>| List of entities                                       |
| *number of componet<br>byte data lists*                                     | 4                | How many lists of<br>component bytes (N<sup>2</sup>)   |
| \|- *component byte list <br>\|&nbsp;&nbsp;**size** M out of N<sup>2</sup>* | 4                | How many bytes are in the<br> subsequent list (M)      |
| \|- *component byte list <br>\|&nbsp;&nbsp;M out of N<sup>2</sup>*          | 1 * M            | Component data as bytes                                |

