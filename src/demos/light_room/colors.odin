package main

import rl "vendor:raylib"

// Surfaces of the room (sRGB; the looks light them in linear color)
FLOOR_TILE_A :: rl.Color{150, 138, 122, 255}
FLOOR_TILE_B :: rl.Color{104, 98, 92, 255}
GROUT :: rl.Color{58, 54, 50, 255}
WALL :: rl.Color{178, 182, 190, 255}
TRIM :: rl.Color{70, 72, 80, 255}
CEILING :: rl.Color{150, 150, 156, 255}
FOIL :: rl.Color{214, 216, 224, 255} // the balloon letters' silver foil
CABLE :: rl.Color{40, 38, 36, 255}

// Props: the hatch's steel and its rust, the lamp's painted metal
STEEL :: rl.Color{84, 82, 80, 255}
RUST :: rl.Color{122, 62, 30, 255}
LAMP_METAL :: rl.Color{44, 48, 52, 255}

// The flood, murky seawater: as lit (the jet, spray), its foam, the film running down the
// walls; and in linear light, the murk the water scatters towards the eye, the rain falling
// from the ceiling, the bubbles' silvery rims
SEAWATER :: rl.Color{44, 80, 108, 255}
FOAM :: rl.Color{192, 208, 222, 255}
WET_FILM :: rl.Color{40, 54, 70, 255}
MURK :: [4]f32{0.005, 0.016, 0.030, 0}
RAIN_LIGHT :: [4]f32{0.032, 0.045, 0.06, 0}
BUBBLE_LIGHT :: [4]f32{0.08, 0.10, 0.115, 0}

// Scene 2, the cave under the sea, in AlgoGame's colors: the rock, the silt over the floor and
// the seabed's sand; the corals (teal, from the trunk to the glowing tips), the sea fans
// (rusty orange to the tips, a glow running up them), the spores; and in linear light the
// water's own: its two tints (AlgoGame's fog), the dark of the deep below, what reaches
// everything from the water around (from above and from below)
ROCK :: rl.Color{62, 62, 70, 255}
ROCK_DARK :: rl.Color{24, 24, 29, 255}
SILT :: rl.Color{74, 70, 64, 255}
SAND :: rl.Color{92, 84, 72, 255}
CORAL_TRUNK :: rl.Color{0x24, 0x4f, 0x57, 255}
CORAL_TIP :: rl.Color{0x5f, 0xc9, 0xb0, 255}
CORAL_GLOW :: rl.Color{0x7f, 0xff, 0xd8, 255}
SEA_FAN_BASE :: rl.Color{150, 60, 40, 255}
SEA_FAN_TIP :: rl.Color{245, 140, 80, 255}
SEA_FAN_GLOW :: rl.Color{0xff, 0xa5, 0x46, 255}
SPORE :: rl.Color{0x9f, 0xe8, 0xd0, 255}
SPORE_WARM :: rl.Color{0xf0, 0xd8, 0x90, 255}
FOG_A :: rl.Color{0x1d, 0x3a, 0x5c, 255}
FOG_B :: rl.Color{0x3b, 0x1f, 0x5a, 255}
SEA_BACKGROUND :: rl.Color{0x07, 0x08, 0x0d, 255} // AlgoGame's dark water, behind its fog
SEA_FAR :: rl.Color{0x0b, 0x0d, 0x18, 255} // what is seen through much of it: about its mean with the fog
SEA_AMBIENT_SKY :: [4]f32{0.010, 0.020, 0.036, 0}
SEA_AMBIENT_GROUND :: [4]f32{0.008, 0.012, 0.018, 0}

// Light that reaches everything a little (linear): from above and from the floor
AMBIENT_SKY :: [4]f32{0.030, 0.032, 0.040, 0}
AMBIENT_GROUND :: [4]f32{0.022, 0.018, 0.014, 0}
// The faint glow of the air itself where the haze is deep (linear)
HAZE_GLOW :: [4]f32{0.020, 0.022, 0.030, 0}

HUD_TEXT :: rl.Color{220, 222, 230, 255}
BACKGROUND :: rl.Color{0, 0, 0, 255}

// The pipe letters of the deep: orange rust, darker where it runs, bare grey metal, brown crust
PIPE_RUST :: rl.Color{188, 90, 40, 255}
PIPE_RUST_DEEP :: rl.Color{120, 52, 24, 255}
PIPE_METAL :: rl.Color{122, 128, 132, 255}
PIPE_CRUST :: rl.Color{132, 84, 50, 255}
