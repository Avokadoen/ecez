pub const Color = struct {
    pub const storage = Light.turquoise;
    pub const archetype = Light.red;
    pub const opaque_archetype = Light.blue;
    pub const arche_container = Light.green;
    pub const entity_builder = Light.purple;
    pub const serializer = Light.brown;
    pub const iterator = Light.orange;
    pub const tree = Light.pink;
    pub const scheduler = Light.lime;
    pub const job_queue = Dark.pink;

    pub const Light = struct {
        pub const red = 0xeb_80_7b;
        pub const orange = 0xff_9c_33;
        pub const yellow = 0xfa_fa_81;
        pub const green = 0x5d_de_6b;
        pub const turquoise = 0x81_fa_fa;
        pub const blue = 0x5d_88_de;
        pub const purple = 0xed_81_fa;
        pub const brown = 0x9e_76_48;
        pub const pink = 0xf2_5d_f5;
        pub const lime = 0xb9_ff_78;
    };

    pub const Dark = struct {
        pub const pink = 0x94_15_30;
    };
};
