#
# Copyright (c) 2025-2026 gremlin art
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

## Nim implementation of Python `autoscrub` make-filtergraph
## except silence at beginning and end of video are not skipped.
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
## * --silent-volume
##
## Features "partially" implemented:
## * --hasten-audio (always tempo)
## * --show-ffmpeg-output (enabled in devel mode)
## * --suppress-prompts (always enabled)

import std/[sequtils, strformat, strutils, with]
import ffmpeg

const
  a_in = "[0:a]"
  v_in = "[0:v]"
  a_out = "[a]"
  v_out = "[v]"
  setpts = "setpts=PTS-STARTPTS"

type
  FilterGraph* = object
    nodes: seq[string]
    segments: Natural         ## count of a/v segments in `nodes`
    segment_end: float        ## timestamp of last a/v segment in `nodes`
    silence* {.requiresInit.}: ptr Silence
  
  Silence* = object           ## type describing silences to scrub
    mininum_duration*: float  ## in seconds (--silence-duration)
    margin: float             ## seconds after start & before end of Segment (--delay)
    segments*: seq[Segment]   ## start/end timestamps silent a/v segments
    speed = 8.0               ## to fast forward (--speed)
    threshold* = -18.0        ## decibels considered silent (--target-threshold)

func initSilence*(margin = 0.25, mininum_duration = 2.0): Silence =
  ## By default, fast forward 2.0+ seconds of silence (silent segment)
  ## except the first and last 0.25 seconds `margin` of each silent segment.
  # autoscrub-0.7.5/scripts/cli.py:make_filtergraph()
  assert margin >= 0
  assert mininum_duration > 0
  assert margin < mininum_duration / 2, fmt"{margin=} must be less than half of {mininum_duration=}"
  Silence(
    mininum_duration: mininum_duration,
    margin: margin,
    )

using g: var FilterGraph

func trim_filters(g; seg: Segment): tuple[before_silence, the_silence: string] =
  ## Returns `trim` filters that target before and during `silence` segment.
  ##
  ## .. note:: unlike Python autoscrub, there is no "delay" at very beginning
  ##   and very end of video.
  var start = seg.start
  result.before_silence =
    if seg.start <= 0:
      fmt"trim=end={start}" # very beginning
    else:
      start += g.silence.margin # "delay"
      fmt"trim={g.segment_end}:{start}"
  
  g.segment_end = seg.end
  result.the_silence =
    if seg.end == 0:
      fmt"trim=start={start}" # till very end
    else:
      g.segment_end -= g.silence.margin
      fmt"trim={start}:{g.segment_end}"

func add(g; video_filters, audio_filters: openarray[string]) =
  inc g.segments
  let n = g.segments
  g.nodes.add [
    fmt"{v_in} {csv video_filters} [v{n}]",
    fmt"{a_in} {csv audio_filters} [a{n}]"
    ]

func audio_filter(filter: string): string =
  ## Returns audio version of `filter`.
  assert ["copy", "setpts", "trim"].anyIt filter.startsWith it & "="
  "a" & filter

func add(g; filters: openarray[string]) =
  g.add filters, filters.mapIt audio_filter it

func filter_to_speedup_audio(g): string =
  csv [audio_filter setpts, speedup_audio_tempo g.silence.speed]

func filter_to_speedup_video(g): string =
  fmt"setpts=(PTS-STARTPTS)/{g.silence.speed}"

func trim_silences(g) =
  ## Fast-forward silent parts of video.
  ##
  ## .. note:: does not ignore silence at beginning and end of video
  ##   unlike Python autoscrub.
  let
    speedup_audio = g.filter_to_speedup_audio
    speedup_video = g.filter_to_speedup_video
  for segment in g.silence.segments:
    let trim = g.trim_filters segment
    g.add [trim.before_silence, setpts]
    g.add [trim.the_silence, speedup_video], [audio_filter trim.the_silence, speedup_audio]

func keep_final_segment(g) =
  ## Appends remaining video after the last silence.
  if g.silence.segments.len == 0:
    g.add ["copy"]
  elif g.segment_end != 0:
    g.add [fmt"trim=start={g.segment_end}", setpts]

func concat_segments(g) =
  ## Appends filter to concatenate A/V segments in `g` Filtergraph.
  assert g.nodes.len != 0
  assert g.nodes.len div 2 == g.segments
  var filter: string
  for n in 1 .. g.segments:
    filter.add fmt"[v{n}][a{n}] "
  
  g.nodes.add filter & fmt"concat=n={g.segments}:v=1:a=1 {v_out} {a_out}"

func scrub_silences*(g) =
  ## Generates filtergraph that speeds up silences.
  # autoscrub-0.7.5/__init__.py:silenceFilterGraph()
  with g:
    trim_silences
    keep_final_segment
    concat_segments

func finally_adjust_volume*(g; gain: float) =
  ## Adjusts audio "gain" at very end of filtergraph.
  # autoscrub-0.7.5/__init__.py:panGainAudioGraph()
  if gain == 0: return
  
  template last_node: auto = g.nodes[^1]
  
  const a_in = "[an]"
  assert last_node.endsWith a_out
  last_node.removeSuffix a_out
  last_node.add a_in
  
  g.nodes.add fmt"{a_in} volume={gain}dB {a_out}"

func complex_filtergraph*(g): string =
  ## Returns formatted text for :program:`ffmpeg` -filter_complex argument.
  assert g.nodes.len != 0
  result = g.nodes.join ";\n"
  result &= ";"
