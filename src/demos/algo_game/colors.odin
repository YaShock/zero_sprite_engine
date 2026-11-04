package main

import rl "vendor:raylib"

// AlgoGame's palette (PALETTE in index-pixi.html)
BACKGROUND :: rl.Color{0x07, 0x08, 0x0d, 255}
WALL :: rl.Color{0x16, 0x16, 0x1a, 255} // the rock's base
PORE :: rl.Color{0x07, 0x08, 0x0b, 255} // small dark fragments in the rock
PORE_RIM :: rl.Color{130, 135, 150, 33} // their faint lit lower lip
PEBBLE_SHADOW :: rl.Color{0, 0, 0, 128}
PEBBLE_SHINE :: rl.Color{255, 240, 220, 23}
SAND_LIGHT :: rl.Color{255, 235, 210, 15}
SAND_DARK :: rl.Color{0, 0, 0, 64}
VIGNETTE :: rl.Color{3, 3, 6, 255} // the rock fades to this toward the screen's top and bottom

// Quit menu
MENU_DIM :: rl.Color{0x07, 0x08, 0x0d, 150} // laid over the game
MENU_PANEL :: rl.Color{0x10, 0x12, 0x1c, 235}
MENU_BORDER :: rl.Color{0x5a, 0x63, 0x80, 255}
MENU_BUTTON :: rl.Color{0x1c, 0x20, 0x2e, 255}
MENU_BUTTON_HOVER :: rl.Color{0x2e, 0x5a, 0x60, 255}
MENU_BUTTON_GLOW :: rl.Color{0x7f, 0xff, 0xd8, 255}

SPARK :: rl.Color{0xff, 0xe0, 0x8a, 255}
TEXT :: rl.Color{0x5a, 0x63, 0x80, 255}
SCORE :: rl.Color{0xe8, 0xec, 0xf8, 255}

// Ship: metallic hull shading, top to bottom
SHIP :: rl.Color{0xd2, 0xce, 0xc6, 255} // tendril parts facing the viewer
SHIP_HELIX_MID :: rl.Color{0x9c, 0x97, 0x8f, 255}
SHIP_HELIX_BACK :: rl.Color{0x5f, 0x5b, 0x55, 255}
SHIP_HIGHLIGHT :: rl.Color{0xfa, 0xf8, 0xf4, 255}
SHIP_LIGHT :: rl.Color{0xe0, 0xdc, 0xd4, 255}
SHIP_MID :: rl.Color{0xb3, 0xae, 0xa5, 255}
SHIP_DARK :: rl.Color{0x6e, 0x69, 0x61, 255}
SHIP_BOUNCE :: rl.Color{0x95, 0x8f, 0x86, 255}
SHIP_EDGE :: rl.Color{0x2e, 0x2b, 0x27, 255}
SHIP_SEAM :: rl.Color{0x77, 0x72, 0x6a, 255}
SHIP_GRAIN :: rl.Color{255, 255, 255, 18}
SHIP_VISOR :: rl.Color{0xe6, 0xec, 0xef, 255}

// Corals and sea fans
CORAL_TRUNK :: [3]f32{0x24, 0x4f, 0x57} // blended toward the tip color by branch level
CORAL_TIP :: [3]f32{0x5f, 0xc9, 0xb0}
CORAL_GLOW :: rl.Color{0x7f, 0xff, 0xd8, 255}
SEA_FAN_BASE :: rl.Color{150, 60, 40, 255} // blended toward the tip color by branch level
SEA_FAN_TIP :: rl.Color{245, 140, 80, 255}
SEA_FAN_LINK :: rl.Color{245, 140, 80, 128}
SEA_FAN_GLOW :: rl.Color{0xff, 0xa5, 0x46, 255}

// Tentacles and goo
TENTACLE :: rl.Color{0x4e, 0x26, 0x45, 255}
TENTACLE_EDGE :: rl.Color{0x9a, 0x4d, 0x7e, 255}
TENTACLE_GLOW :: rl.Color{0xff, 0x8a, 0xd0, 255}
GOO :: rl.Color{0x34, 0x46, 0x1c, 255}
GOO_EDGE :: rl.Color{0x9c, 0xc2, 0x4a, 255}
GOLD :: rl.Color{0x9a, 0x74, 0x14, 255} // a caught droplet turns from the goo colors to these
GOLD_EDGE :: rl.Color{0xff, 0xd2, 0x4a, 255}
DROPLET_TEXT :: rl.Color{0xff, 0xf8, 0xe0, 255}

// Atmosphere
FOG_A :: [3]f32{0x1d, 0x3a, 0x5c} // the fog shifts between these two tints
FOG_B :: [3]f32{0x3b, 0x1f, 0x5a}
SPORE :: rl.Color{0x9f, 0xe8, 0xd0, 255}
SPORE_WARM :: rl.Color{0xf0, 0xd8, 0x90, 255} // one spore in five
// Light colors by LightKind: corals, sea fans, tentacles
LIGHT_COLORS := [LightKind]rl.Color {
	.Coral    = CORAL_GLOW,
	.Fan      = SEA_FAN_GLOW,
	.Tentacle = TENTACLE_GLOW,
}
