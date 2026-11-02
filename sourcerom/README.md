# sourcerom

Put the NES ROM images you own here (iNES `.nes` files). They are ignored by
git and never distributed with this project.

The sample recipes in the main README expect these names:

| File                 | Game                                   |
|----------------------|----------------------------------------|
| `contra.nes`         | Contra (USA)                           |
| `doubledragonii.nes` | Double Dragon II: The Revenge (USA)    |
| `supermariobros.nes` | Super Mario Bros. (Japan, USA)         |

`make ROM=contra` then builds `build/contra/contra.rom`. The README lists the
SHA-1 of each image the samples were tested with.
