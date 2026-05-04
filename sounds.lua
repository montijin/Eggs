require('common');
local chat = require('chat');
------------------------------------------------------------
-- sounds.lua  (Eggs v1.0 - by Monti)
------------------------------------------------------------

local sounds = {};

sounds.Available = {
    { id = 'chime',   label = 'Chirp',        file = 'chime.wav'  },
    { id = 'bell',    label = 'Bell',          file = 'bell.wav'   },
    { id = 'alert',   label = 'Alert Beep',    file = 'alert.wav'  },
    { id = 'alarm',   label = 'Alarm',        file = 'alarm.wav'  },
    { id = 'bellx2',  label = 'Double Bell',   file = 'bellx2.wav' },
};

sounds.Initialize = function(self)
    local base = string.format('%ssounds/', addon.path);
    for _, s in ipairs(self.Available) do
        if not ashita.fs.exists(base .. s.file) then
            print(chat.header('Eggs') .. chat.message(
                'Sound missing: sounds/' .. s.file));
        end
    end
end;

sounds.Play = function(self, sound_id)
    local base = string.format('%ssounds/', addon.path);
    -- Find the sound
    local target_file = nil;
    for _, s in ipairs(self.Available) do
        if s.id == sound_id then
            target_file = base .. s.file;
            break;
        end
    end
    -- Fallback to first available
    if not target_file then
        for _, s in ipairs(self.Available) do
            local p = base .. s.file;
            if ashita.fs.exists(p) then target_file = p; break; end
        end
    end
    if not target_file then return; end
    if not ashita.fs.exists(target_file) then return; end

    -- Apply volume: use Windows volume scaling via SoundFile or just play directly
    -- Ashita v4 ashita.sound.play does not expose volume, but we write a scaled
    -- copy if volume != 100 (simple approach: just play at system volume for now)
    local vol = gSettings and gSettings.alarm_volume or 100;
    if vol <= 0 then return; end  -- muted

    pcall(ashita.misc.play_sound, target_file);
end;

sounds.GetLabel = function(self, sound_id)
    for _, s in ipairs(self.Available) do
        if s.id == sound_id then return s.label; end
    end
    return sound_id;
end;

return sounds;
