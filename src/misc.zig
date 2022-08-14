pub const Color = struct {
    pub const world = Light.turquoise;
    pub const archetype = Light.red;
    pub const arche_container = Light.green;
    pub const entity_builder = Light.purple;

    pub const Light = struct {
        pub const red = 0xeb_80_7b;
        pub const orange = 0xff_9c_33;
        pub const yellow = 0xfa_fa_81;
        pub const green = 0x5d_de_6b;
        pub const turquoise = 0x81_fa_fa;
        pub const blue = 0x5d_88_de;
        pub const purple = 0xed_81_fa;
    };
};
