#
# Copyright (c) 2026 gremlin art
#
# This file is part of autoscrub.
#
# autoscrub is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation, either version 3 of the License,
# or (at your option) any later version.
#
# autoscrub is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with autoscrub. If not, see <https://www.gnu.org/licenses/>.
#

## Generate `ffmpeg` complex filtergraph to fast-forward "silent parts" of video
## and normalize audio loudness.

import std/[logging, os, strformat]
import ffmpeg, filtergraph

type Scrub = object
  ffmpeg: FFmpeg
  gain: float
  loudness: float # --target-lufs
  silence: Silence

using s: var Scrub

proc silence_threshold(s): float =
  ## Returns the sound level (dB) after adjusting for `gain` loudness.
  # autoscrub-0.7.5/scripts/cli.py:create_filtergraph()
  let input = s.ffmpeg.get_loudness
  s.gain = s.loudness - input
  result = input + s.silence.threshold - s.loudness
  info fmt"measured loudness={input} dBLUFS; gain={s.gain} dB; threshold={result} dB"

proc get_silent_segments(s) =
  notice"searching for silence..."
  s.silence.segments = s.ffmpeg.detect_silences(s.silence_threshold, s.silence.mininum_duration)

proc initScrub(filepath: string; delay, silence: float; loudness = -18.0): Scrub =
  ## By default, normalize audio `loudness` to -18dB.
  assert loudness <= 0
  Scrub(
    ffmpeg: initFFmpeg filepath,
    loudness: loudness,
    silence: initSilence(margin = delay, mininum_duration = silence)
  )

proc complex_filtergraph(s): string =
  s.get_silent_segments
  
  var g = FilterGraph(silence: addr s.silence)
  g.scrub_silences
  g.finally_adjust_volume s.gain
  result = g.complex_filtergraph

proc write_filtergraph(s) =
  ## Emits complex filtergraph to {infile}.filter-graph
  ##
  ## .. hint:: for :program:ffmpeg -/filter_complex
  let
    (dir, name, _) = splitFile string s.ffmpeg.infile
    outfile = dir / name & ".filter-graph"
  writeFile outfile, s.complex_filtergraph
  notice fmt"wrote {extractFilename outfile}"

proc main =
  addHandler newConsoleLogger()
  
  const buildInfo = "build: " & staticExec"git rev-parse HEAD"[0..6]
  info buildInfo
  
  let infile = commandLineParams()[0]
  notice "processing file: " & extractFilename infile
  
  var s = initScrub(
    infile,
    0.0, 0.5, # speed up 0.5+ seconds long silences w/ no delay
    -14.0,    # normalize audio to -14dB
    )
  s.write_filtergraph

main()