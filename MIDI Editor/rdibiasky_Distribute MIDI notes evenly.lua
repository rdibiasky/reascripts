-- @description Evenly space selected MIDI notes
-- @version 1.0
-- @author rdibiasky
-- @about
--   This script evenly spaces selected MIDI notes in the active MIDI editor.

local editor = reaper.MIDIEditor_GetActive()
if not editor then return end

local take = reaper.MIDIEditor_GetTake(editor)
if not take or not reaper.TakeIsMIDI(take) then return end

local _, noteCount, _, _ = reaper.MIDI_CountEvts(take)

local notes = {}
for i = 0, noteCount - 1 do
  local ok, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
  if ok and selected then
    notes[#notes + 1] = {
      idx = i,
      startppq = startppq,
      endppq = endppq,
      chan = chan,
      pitch = pitch,
      vel = vel,
      muted = muted
    }
  end
end

if #notes < 2 then return end

table.sort(notes, function(a, b) return a.startppq < b.startppq end)

local firstPos = notes[1].startppq
local lastPos  = notes[#notes].startppq
local step = (lastPos - firstPos) / (#notes - 1)

reaper.Undo_BeginBlock()
reaper.MIDI_DisableSort(take)

for i = 1, #notes do
  local newStart = math.floor(firstPos + (i - 1) * step + 0.5)
  local length = notes[i].endppq - notes[i].startppq
  local newEnd = newStart + length

  reaper.MIDI_SetNote(
    take,
    notes[i].idx,
    true,
    notes[i].muted,
    newStart,
    newEnd,
    notes[i].chan,
    notes[i].pitch,
    notes[i].vel,
    true
  )
end

reaper.MIDI_Sort(take)
reaper.Undo_EndBlock("Distribute MIDI notes evenly", -1)
reaper.UpdateArrange()
