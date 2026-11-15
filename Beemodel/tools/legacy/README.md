# Legacy generators

These scripts generated parts of BeeModel from the assembly BeeModel (its sources
and its binary) while BeeModel was a port of it. Since 2026-11-14 BeeModel is
developed on its own, and the files they made are ordinary source, edited by hand:

| Script | Made |
| --- | --- |
| `gen_catalog.py` | `src/catalog.zig` (commands, menus), `src/themes.zig`, `src/icons.zig`, `src/keysyms.zig` |
| `gen_opundo.py` | `src/opundo.zig` |
| `gen_aisafe.py` | `src/aisafe.zig` |
| `gen_shnodes.py` | `src/shnodes.zig` |
| `gen_graph_oracle.py` | `tests/files/graph_oracle.bin`, the shader graph's golden values |

Don't run them: they need the assembly BeeModel, and they would overwrite the
hand edits made since. They are kept to show where those files came from.
