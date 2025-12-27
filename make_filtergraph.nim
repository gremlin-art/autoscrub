#
# Copyright (c) 2025 gremlin art
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

## Nim implementation of Python `autoscrub make-filtergraph`.
##
## `initScrub proc`_ takes parameters for making filtergraph.
##
## `write_filtergraph proc`_ emits the filtergraph and saves to file.
##
## The complex filtergraph may use `ffmpeg` filters:
## * audio: atrim, atempo, volume
## * video: trim
## * multimedia: concat, setpts / asetpts
##
## Python autoscrub v0.7.5
## -----------------------
## * https://github.com/philipstarkey/autoscrub
## * https://autoscrub.readthedocs.io/en/stable/usage_reference.html
##
## Features "not" implemented:
## * --pan-audio
## * --rescale
## * --show-ffmpeg-output
## * --silent-volume
##
## Features "partially" implemented:
## * --hasten-audio (always tempo)
## * --suppress-prompts (always enabled)

import std/[logging, math, os, sequtils, strformat, strutils]
import ffmpeg

const
  setpts = "setpts=PTS-STARTPTS"
  v_in = "[0:v]"
  a_in = "[0:a]"

type
  FilterGraph = object
    atrim, trim, concat: seq[string]
    silences: int
    end_of_last_silence: float
    scrub: ptr Scrub
  
  Scrub = object
    ffmpeg: FFmpeg
    gain, loudness: float # --target-lufs
    silence: Silence
  ScrubError = object of CatchableError
  
  Silence = object
    mininum_duration: float # in seconds (--silence-duration)
    margin: float           # seconds after start & before end of Segment (--delay)
    segments: Segments
    speed: float = 8        # to fast forward (--speed)
    threshold = -18.0       # decibels considered silent (--target-threshold)

using
  g: var FilterGraph
  s: ptr Scrub

proc speedup_audio_tempo(factor: float): string =
  ## Returns atempo filter for speeding up audio.
  # autoscrub-0.7.5/__init__.py:silenceFilterGraph()
  let
    q = log(factor, 2)  # 2: tempo greater than 2 will skip some samples
    int_q = int trunc q
  assert int_q >= 0
  
  var tempos = ["atempo=2.0"].cycle int_q
  if q != float int_q:
    tempos.add fmt"atempo={factor}/{2 ^ int_q}"
  tempos.join ","

proc silence_threshold(s: var Scrub): float =
  ## Returns the sound level (dB) after adjusting for `gain` loudness.
  # autoscrub-0.7.5/scripts/cli.py:create_filtergraph()
  let input = s.ffmpeg.get_loudness
  s.gain = s.loudness - input
  
  result = input + s.silence.threshold - s.loudness
  info fmt"measured loudness={input} dBLUFS; gain={s.gain} dB; threshold={result} dB"

proc get_silent_segments(s: var Scrub) =
  notice"searching for silence..."
  s.silence.segments = s.ffmpeg.detect_silences(s.silence_threshold, s.silence.mininum_duration)

proc initScrub*(infile: string, delay = 0.25, silence = 2.0, loudness = -18.0): Scrub {.noinit.} =
  ## By default:
  ## * fast forward (8x speed) 2.0+ seconds `silence` except for `delay` that is
  ##   the first and last 0.25 seconds of silence.
  ## * normalize audio `loudness` to -18dB.
  ##
  ## See also:
  ## * `write_filtergraph proc`_
  assert delay >= 0
  assert loudness <= 0
  assert silence > 0
  if delay >= silence / 2: # autoscrub-0.7.5/scripts/cli.py:make_filtergraph()
    raise newException(ScrubError, fmt"{delay=} must be less than half of {silence=}")
  
  notice fmt"processing file: {extractFilename infile}"
  result = Scrub(
    ffmpeg: initFFmpeg infile,
    loudness: loudness,
    silence: Silence(mininum_duration: silence, margin: delay)
  )
  result.get_silent_segments

iterator truncated_silences(s): Segment =
  ## Omits silence at the very start & end of video.
  let segments = s.silence.segments
  if segments.len > 0:
    let
      last = segments.high - (if segments[^1].end == 0: 1 else: 0)
      first = if segments[0].start <= 0: 1 else: 0
    for i in first .. last:
      yield segments[i]

template scrub: ptr Scrub =
  g.scrub

func trim_filters(g; silence: Segment): tuple[before, during: string] =
  ## Returns `trim` filters for before and during `silence` segment.
  let
    delay = scrub.silence.margin
    begin = silence.start + delay
    `end` = silence.end - delay
    last = g.end_of_last_silence
  g.end_of_last_silence = `end`
  
  ( fmt"trim={last}:{begin}", fmt"trim={begin}:{`end`}" )

func next_segment(g): tuple[before, during: int] =
  ## Returns the segment before and during silence.
  inc g.silences # 1-based
  let silence = 2 * g.silences
  (silence - 1, silence)

proc trim_silences(g) =
  ## Updates `g` FilterGraph to fast-forward silent parts of video.
  ##
  ## .. note:: ignores silence at very beginning and end of video.
  # autoscrub-0.7.5/__init__.py:silenceFilterGraph()
  assert g.silences == 0
  let
    factor = scrub.silence.speed
    speedup_audio = speedup_audio_tempo factor
    speedup_video = fmt"setpts=(PTS-STARTPTS)/{factor}"
  for silence in scrub.truncated_silences:
    let
      segment = g.next_segment
      trim = g.trim_filters silence
    
    g.trim.add [
      fmt"{v_in} {trim.before}, {setpts} [v{segment.before}];",
      fmt"{v_in} {trim.during}, {speedup_video} [v{segment.during}];"
      ]
    
    g.atrim.add [
      fmt"{a_in} a{trim.before}, a{setpts} [a{segment.before}];",
      fmt"{a_in} a{trim.during}, a{setpts}, {speedup_audio} [a{segment.during}];"
      ]
    
    g.concat.add fmt"[v{segment.before}] [a{segment.before}] [v{segment.during}] [a{segment.during}]"

proc complex_filtergraph(g): string =
  # autoscrub-0.7.5/__init__.py:silenceFilterGraph()
  let
    nodes = g.silences * 2 + 1 # video & audio + concat
    trim_till_end = fmt"trim=start={g.end_of_last_silence}"
  g.trim.add fmt"{v_in} {trim_till_end}, {setpts} [v{nodes}];"
  g.atrim.add fmt"{a_in} a{trim_till_end}, a{setpts} [a{nodes}];"
  
  let a_out = if scrub.gain != 0: "[an]" else: "[a]" # an: for `loudness_filtergraph proc`_
  g.concat.add fmt"[v{nodes}] [a{nodes}] concat=n={nodes}:v=1:a=1 [v] {a_out};"
  
  [g.trim.join "\n", g.atrim.join "\n", g.concat.join" "].join "\n"

proc silence_filtergraph(s: Scrub): string =
  ## Returns the complex filtergraph for speeding up silences.
  var g = FilterGraph(scrub: addr s)
  g.trim_silences
  g.complex_filtergraph

proc loudness_filtergraph(s: Scrub): string =
  ## Returns complex filtergraph to adjust audio volume.
  ##
  ## .. note:: Returns empty string when no "gain" adjustment is needed.
  # autoscrub-0.7.5/__init__.py:panGainAudioGraph()
  if s.gain != 0:
    return fmt "\n[an] volume={s.gain}dB [a];"

proc write_filtergraph*(s: Scrub) =
  ## Generates the complex filtergraph and writes to {infile}.filter-graph file
  ## in the same directory as the video (infile).
  ##
  ## .. hint:: for :program:ffmpeg -/filter_complex
  let
    (dir, name, _) = splitFile string s.ffmpeg.infile
    outfile = dir / name & ".filter-graph"
  writeFile outfile, s.silence_filtergraph & s.loudness_filtergraph
  notice fmt"wrote {extractFilename outfile}"

when isMainModule:
  ## Generate complex filtergraph to fast-forward "silent parts" of
  ## video and normalize audio loudness.
  ##
  ## Usage example:
  ## * make_filtergraph {short_video}.mkv
  ## * ffmpeg -i {short_video}.mkv -/complex_filter {short_video}.filter-graph ...
  import std/cmdline

  const buildInfo = "build: " & staticExec"git rev-parse HEAD"[0..6]
  addHandler newConsoleLogger()
  info buildInfo

  let infile = commandLineParams()[0]
  var s = initScrub(
    infile,
    0.0, 0.5, # speed up 0.5+ seconds long silences w/ no delay
    -14.0,    # normalize audio to -14dB
    )
  s.write_filtergraph
