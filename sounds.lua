require('common');
local chat = require('chat');
local ffi  = require('ffi');
------------------------------------------------------------
-- sounds.lua  (Eggs v1.01 - by Monti)
-- Uses IDirectSoundBuffer8 for per-play volume control.
-- Falls back to ashita.misc.play_sound on any DS failure.
-- Technique adapted from partyfinder by CatsEyeXI (MIT).
------------------------------------------------------------

-- DirectSound COM interface declarations
ffi.cdef[[
typedef unsigned long  DWORD;
typedef long           LONG;
typedef long           HRESULT;
typedef unsigned short WORD;
typedef void*          HWND;

typedef struct {
    DWORD         Data1;
    WORD          Data2;
    WORD          Data3;
    unsigned char Data4[8];
} GUID;

typedef struct {
    WORD  wFormatTag;
    WORD  nChannels;
    DWORD nSamplesPerSec;
    DWORD nAvgBytesPerSec;
    WORD  nBlockAlign;
    WORD  wBitsPerSample;
    WORD  cbSize;
} WAVEFORMATEX;

typedef struct {
    DWORD         dwSize;
    DWORD         dwFlags;
    DWORD         dwBufferBytes;
    DWORD         dwReserved;
    WAVEFORMATEX* lpwfxFormat;
    GUID          guid3DAlgorithm;
} DSBUFFERDESC;

typedef struct IDirectSoundBuffer IDirectSoundBuffer;
typedef struct {
    HRESULT       (__stdcall *QueryInterface)(void*, const GUID*, void**);
    unsigned long (__stdcall *AddRef)(void*);
    unsigned long (__stdcall *Release)(void*);
    HRESULT       (__stdcall *GetCaps)(void*, void*);
    HRESULT       (__stdcall *GetCurrentPosition)(void*, DWORD*, DWORD*);
    HRESULT       (__stdcall *GetFormat)(void*, void*, DWORD, DWORD*);
    HRESULT       (__stdcall *GetVolume)(void*, LONG*);
    HRESULT       (__stdcall *GetPan)(void*, LONG*);
    HRESULT       (__stdcall *GetFrequency)(void*, DWORD*);
    HRESULT       (__stdcall *GetStatus)(void*, DWORD*);
    HRESULT       (__stdcall *Initialize)(void*, void*, const DSBUFFERDESC*);
    HRESULT       (__stdcall *Lock)(void*, DWORD, DWORD, void**, DWORD*, void**, DWORD*, DWORD);
    HRESULT       (__stdcall *Play)(void*, DWORD, DWORD, DWORD);
    HRESULT       (__stdcall *SetCurrentPosition)(void*, DWORD);
    HRESULT       (__stdcall *SetFormat)(void*, const WAVEFORMATEX*);
    HRESULT       (__stdcall *SetVolume)(void*, LONG);
    HRESULT       (__stdcall *SetPan)(void*, LONG);
    HRESULT       (__stdcall *SetFrequency)(void*, DWORD);
    HRESULT       (__stdcall *Stop)(void*);
    HRESULT       (__stdcall *Unlock)(void*, void*, DWORD, void*, DWORD);
    HRESULT       (__stdcall *Restore)(void*);
} IDirectSoundBufferVtbl;
struct IDirectSoundBuffer { IDirectSoundBufferVtbl* lpVtbl; };

typedef struct IDirectSound8 IDirectSound8;
typedef struct {
    HRESULT       (__stdcall *QueryInterface)(void*, const GUID*, void**);
    unsigned long (__stdcall *AddRef)(void*);
    unsigned long (__stdcall *Release)(void*);
    HRESULT       (__stdcall *CreateSoundBuffer)(void*, const DSBUFFERDESC*, IDirectSoundBuffer**, void*);
    HRESULT       (__stdcall *GetCaps)(void*, void*);
    HRESULT       (__stdcall *DuplicateSoundBuffer)(void*, void*, void**);
    HRESULT       (__stdcall *SetCooperativeLevel)(void*, HWND, DWORD);
    HRESULT       (__stdcall *Compact)(void*);
    HRESULT       (__stdcall *GetSpeakerConfig)(void*, DWORD*);
    HRESULT       (__stdcall *SetSpeakerConfig)(void*, DWORD);
    HRESULT       (__stdcall *Initialize)(void*, const GUID*);
} IDirectSound8Vtbl;
struct IDirectSound8 { IDirectSound8Vtbl* lpVtbl; };

HRESULT __stdcall DirectSoundCreate8(const GUID*, IDirectSound8**, void*);
HWND    __stdcall GetForegroundWindow();
HWND    __stdcall GetDesktopWindow();
HWND    __stdcall FindWindowA(const char*, const char*);
]]

local DSSCL_NORMAL        = 0x1;
local DSBCAPS_STATIC      = 0x4;
local DSBCAPS_LOCSOFTWARE = 0x8;
local DSBCAPS_CTRLVOLUME  = 0x80;
local DSBCAPS_GLOBALFOCUS = 0x8000;
local DSBVOLUME_MIN       = -10000;
local WAVE_FORMAT_PCM     = 0x0001;

-- Try flag combinations in decreasing order; some Win10/11 DS shims reject certain combos.
local FLAG_TRIES = {
    { DSBCAPS_CTRLVOLUME + DSBCAPS_STATIC + DSBCAPS_GLOBALFOCUS + DSBCAPS_LOCSOFTWARE },
    { DSBCAPS_CTRLVOLUME + DSBCAPS_STATIC + DSBCAPS_LOCSOFTWARE },
    { DSBCAPS_CTRLVOLUME + DSBCAPS_LOCSOFTWARE },
    { DSBCAPS_CTRLVOLUME + DSBCAPS_STATIC },
    { DSBCAPS_CTRLVOLUME },
};

-- Load dsound and user32 DLLs; either may be nil if unavailable.
local dsound, user32;
do
    local ok, mod;
    ok, mod = pcall(ffi.load, 'dsound'); if ok then dsound = mod; end
    ok, mod = pcall(ffi.load, 'user32'); if ok then user32 = mod; end
end

------------------------------------------------------------
-- WAV parsing helpers
------------------------------------------------------------
local function read_u16(s, i) return s:byte(i) + s:byte(i+1)*256; end
local function read_u32(s, i)
    return s:byte(i) + s:byte(i+1)*256 + s:byte(i+2)*65536 + s:byte(i+3)*16777216;
end

local function parse_wav(data)
    if #data < 44 then return nil, 'file too short'; end
    if data:sub(1,4) ~= 'RIFF' or data:sub(9,12) ~= 'WAVE' then
        return nil, 'not RIFF/WAVE';
    end
    local fmt, data_offset, data_len;
    local pos = 13;
    while pos + 8 <= #data do
        local chunk_id   = data:sub(pos, pos+3);
        local chunk_size = read_u32(data, pos+4);
        local body       = pos + 8;
        if chunk_id == 'fmt ' then
            if chunk_size < 16 then return nil, 'fmt chunk too small'; end
            fmt = {
                wFormatTag      = read_u16(data, body),
                nChannels       = read_u16(data, body+2),
                nSamplesPerSec  = read_u32(data, body+4),
                nAvgBytesPerSec = read_u32(data, body+8),
                nBlockAlign     = read_u16(data, body+12),
                wBitsPerSample  = read_u16(data, body+14),
            };
        elseif chunk_id == 'data' then
            data_offset = body;
            data_len    = chunk_size;
            break;
        end
        pos = body + chunk_size + (chunk_size % 2);
    end
    if not fmt         then return nil, 'no fmt chunk';  end
    if not data_offset then return nil, 'no data chunk'; end
    if fmt.wFormatTag ~= WAVE_FORMAT_PCM then
        return nil, string.format('not PCM (format %d)', fmt.wFormatTag);
    end
    return fmt, data_offset, data_len;
end

-- Convert linear 0-100 to DirectSound millibels (DSBVOLUME_MIN..0).
local function volume_to_db(linear)
    if linear <= 0   then return DSBVOLUME_MIN; end
    if linear >= 100 then return 0; end
    local db = math.floor(2000 * math.log10(linear / 100));
    return math.max(db, DSBVOLUME_MIN);
end

local function ds_release(obj)
    if obj then obj.lpVtbl.Release(obj); end
end

local function load_buffer(ds8, path)
    local f = io.open(path, 'rb');
    if not f then return nil, 'open failed'; end
    local data = f:read('*all');
    f:close();
    if not data or #data == 0 then return nil, 'empty file'; end

    local fmt, data_offset, data_len = parse_wav(data);
    if not fmt then return nil, data_offset; end -- data_offset is error string on failure

    local wfx = ffi.new('WAVEFORMATEX');
    wfx.wFormatTag      = fmt.wFormatTag;
    wfx.nChannels       = fmt.nChannels;
    wfx.nSamplesPerSec  = fmt.nSamplesPerSec;
    wfx.nAvgBytesPerSec = fmt.nAvgBytesPerSec;
    wfx.nBlockAlign     = fmt.nBlockAlign;
    wfx.wBitsPerSample  = fmt.wBitsPerSample;
    wfx.cbSize          = 0;

    local desc = ffi.new('DSBUFFERDESC');
    desc.dwSize        = ffi.sizeof('DSBUFFERDESC');
    desc.dwBufferBytes = data_len;
    desc.dwReserved    = 0;
    desc.lpwfxFormat   = wfx;

    local buf_out = ffi.new('IDirectSoundBuffer*[1]');
    local hr;
    for _, try in ipairs(FLAG_TRIES) do
        desc.dwFlags = try[1];
        hr = ds8.lpVtbl.CreateSoundBuffer(ds8, desc, buf_out, nil);
        if hr == 0 then break; end
    end
    if hr ~= 0 then return nil, string.format('CreateSoundBuffer hr=0x%08X', hr); end

    local buf    = buf_out[0];
    local pcm    = data:sub(data_offset, data_offset + data_len - 1);
    local pcmbuf = ffi.new('uint8_t[?]', data_len);
    ffi.copy(pcmbuf, pcm, data_len);

    local p1   = ffi.new('void*[1]');
    local len1 = ffi.new('DWORD[1]');
    local p2   = ffi.new('void*[1]');
    local len2 = ffi.new('DWORD[1]');
    hr = buf.lpVtbl.Lock(buf, 0, data_len, p1, len1, p2, len2, 0);
    if hr ~= 0 then
        ds_release(buf);
        return nil, string.format('Lock hr=0x%08X', hr);
    end
    local n1 = tonumber(len1[0]);
    local n2 = tonumber(len2[0]);
    if n1 > 0 then ffi.copy(p1[0], pcmbuf, n1); end
    if n2 > 0 and p2[0] ~= nil then ffi.copy(p2[0], pcmbuf + n1, n2); end
    buf.lpVtbl.Unlock(buf, p1[0], len1[0], p2[0], len2[0]);

    return buf;
end

------------------------------------------------------------
-- Public sounds module
------------------------------------------------------------
local sounds = {};

sounds.Available = {
    { id = 'chime',  label = 'Chirp',       file = 'chime.wav'  },
    { id = 'bell',   label = 'Bell',         file = 'bell.wav'   },
    { id = 'alert',  label = 'Alert Beep',   file = 'alert.wav'  },
    { id = 'alarm',  label = 'Alarm',        file = 'alarm.wav'  },
    { id = 'bellx2', label = 'Double Bell',  file = 'bellx2.wav' },
};

sounds._ds8      = nil;   -- IDirectSound8*
sounds._buffers  = {};    -- sound_id -> IDirectSoundBuffer*
sounds._paths    = {};    -- sound_id -> filesystem path (fallback)
sounds._ds_ready = false;

sounds.Initialize = function(self)
    local base = string.format('%ssounds/', addon.path);

    -- Record fallback paths and verify files exist
    for _, s in ipairs(self.Available) do
        local path = base .. s.file;
        self._paths[s.id] = path;
        if not ashita.fs.exists(path) then
            print(chat.header('Eggs') .. chat.message('Sound missing: sounds/' .. s.file));
        end
    end

    -- Bail out if DirectSound or user32 didn't load
    if not dsound or not user32 then
        print(chat.header('Eggs') .. chat.message(
            'DirectSound unavailable — volume control disabled, using system audio.'));
        return;
    end

    -- Create IDirectSound8 device
    local ds_out = ffi.new('IDirectSound8*[1]');
    local hr     = dsound.DirectSoundCreate8(nil, ds_out, nil);
    if hr ~= 0 then
        print(chat.header('Eggs') .. chat.message(string.format(
            'DirectSoundCreate8 failed (0x%08X) — volume control disabled.', hr)));
        return;
    end
    local ds8 = ds_out[0];

    -- Attach to the FFXI window so the audio session is correctly associated
    local hwnd = user32.FindWindowA('FFXiClass', nil)
               or user32.GetForegroundWindow()
               or user32.GetDesktopWindow();
    hr = ds8.lpVtbl.SetCooperativeLevel(ds8, hwnd, DSSCL_NORMAL);
    if hr ~= 0 then
        ds_release(ds8);
        print(chat.header('Eggs') .. chat.message(string.format(
            'DS SetCooperativeLevel failed (0x%08X) — volume control disabled.', hr)));
        return;
    end
    self._ds8 = ds8;

    -- Load each WAV into a DirectSound buffer
    for _, s in ipairs(self.Available) do
        local buf, err = load_buffer(ds8, self._paths[s.id]);
        if buf then
            self._buffers[s.id] = buf;
        else
            print(chat.header('Eggs') .. chat.message(
                string.format('DS buffer load failed for %s: %s', s.id, err)));
        end
    end

    self._ds_ready = true;
end;

sounds.Play = function(self, sound_id)
    local vol = (gSettings and gSettings.alarm_volume or 100);
    if vol <= 0 then return; end  -- muted

    -- DirectSound path: SetVolume then play from start
    if self._ds_ready then
        local buf = self._buffers[sound_id];
        if buf then
            local ok = pcall(function()
                buf.lpVtbl.SetVolume(buf, volume_to_db(vol));
                buf.lpVtbl.SetCurrentPosition(buf, 0);
                buf.lpVtbl.Play(buf, 0, 0, 0);
            end);
            if ok then return; end
        end
    end

    -- Fallback: system volume, no attenuation
    local path = self._paths[sound_id];
    if not path then
        -- path unknown — try to find any available sound
        for _, s in ipairs(self.Available) do
            if self._paths[s.id] then path = self._paths[s.id]; break; end
        end
    end
    if path then pcall(ashita.misc.play_sound, path); end
end;

sounds.GetLabel = function(self, sound_id)
    for _, s in ipairs(self.Available) do
        if s.id == sound_id then return s.label; end
    end
    return sound_id;
end;

sounds.Cleanup = function(self)
    for id, buf in pairs(self._buffers) do
        ds_release(buf);
        self._buffers[id] = nil;
    end
    if self._ds8 then
        ds_release(self._ds8);
        self._ds8 = nil;
    end
    self._ds_ready = false;
end;

return sounds;
