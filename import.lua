require('common');
local chat = require('chat');
------------------------------------------------------------
-- import.lua  (Eggs - by Monti)
--
-- The in-game importer is retired. Phoenix moved mob data from SQL dumps and
-- `entity.phList` Lua into per-zone YAML (data/zones/<zone>/mobs.yaml) plus
-- module overlays, which is far too heavy to parse inside the Ashita Lua VM.
--
-- Data files are now produced by tools/generate.py (Python 3 + PyYAML):
--
--     python tools/generate.py --repo C:\Phoenix-Workspace
--
-- then /addon reload eggs.
------------------------------------------------------------

local import_module = {};

import_module.Run = function(self)
    local tools = string.format('%stools\\generate.py', addon.path);
    print(chat.header('Eggs') .. chat.message(
        'The in-game importer was replaced by an external generator.'));
    print(chat.header('Eggs') .. chat.message(
        'Run from a terminal:  python "' .. tools .. '" --repo C:\\Phoenix-Workspace'));
    print(chat.header('Eggs') .. chat.message(
        'Then:  /addon reload eggs   (needs Python 3 + PyYAML: pip install pyyaml)'));
end;

return import_module;
