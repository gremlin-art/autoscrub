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

## Simple interface to ffmpeg CLI (https://ffmpeg.org)
##
## Based on Python autoscrub v0.7.5 (https://github.com/philipstarkey/autoscrub)
##
## Requirements:
## * ffmpeg v6 to v8
##   * `ffmpeg` in your environment path
##   * audio filters: silencedetect
##   * multimedia filters: ebur128
##

import std/[logging, os, osproc, strformat, strutils, with]

type
  FFmpeg* = object
    exe, infile*: FilePath
    version: string
  FFmpegError = object of CatchableError
  FilePath = distinct string
  
  Segment* = tuple[start, `end`: float] # timestamps
  Segments* = seq[Segment]

proc find_exe(filename: string): string =
  ## Wrapper for std/os.findExe proc.
  ##
  ## Raises when `filename` is not found.
  result = os.findExe filename
  if result == "":
    raise newException(FFmpegError, fmt"{filename} not in path")

proc exec(cmd: FilePath; args: openArray[string]; begins_with = ""; last: Natural = 0): seq[string] =
  ## Executes `cmd` with given `args` and returns the output.
  ##
  ## Raises on non-zero exit code.
  var po = {poStdErrToStdOut}
  when not defined release: po.incl poEchoCmd
  let p = startProcess(string cmd, args=args, options=po)
  defer: close p
  
  for line in p.lines:
    if begins_with != "" and not line.startsWith begins_with:
      continue
    result.add line
    
    if last != 0 and result.len > last:
      result.delete 0
  
  let exitCode = p.peekExitCode
  if exitCode != 0:
    raise newException(FFmpegError, fmt"{exitCode=}")

using f: FFmpeg

proc exec(f; options: openArray[string]; begins_with = ""; last = 0): seq[string] =
  ## Executes :program:`ffmpeg` with given arguments and returns the output.
  var args = @[
    "-hide_banner",
    "-nostats",
    "-i", string f.infile
    ]
  
  args.add options
  
  f.exe.exec(args, begins_with, last)

func major_version(f): int =
  parseInt f.version.substr(1).split('.', 1)[0]

proc get_version(f: var FFmpeg) =
  f.version = f.exe.exec(["-hide_banner", "-version"])[0].splitWhitespace(3)[2]
  info fmt"ffmpeg version: {f.version}" # eg. n7.1.3-14-ga...

proc initFFmpeg*(infile: string): FFmpeg =
  with result:
    exe = FilePath find_exe"ffmpeg"
    infile = FilePath infile
    get_version

template parseIt(label, body) =
  idx = line.find label
  if idx != -1:
    let it {.inject.} = line[idx + label.len + 2 ..^ 1]
    body

proc detect_silences*(f; threshold, duration: float): Segments =
  ## Scans audio with silencedetect filter.
  ## Returns the timestamps of silences.
  # autoscrub-0.7.5/scripts/cli.py:create_filtergraph()
  let output = f.exec(
    begins_with = "[silencedetect ",
    options = [
      "-af", fmt"silencedetect=n={threshold}dB:d={duration}",
      "-f", "null",
      "-"
    ])
  
  var total_duration: float
  for line in output:
    var idx: int
    parseIt "silence_start":
      result.add (parseFloat it, 0.0)
      continue
    
    parseIt "silence_end":
      let e = split(it, '|', 1)
      result[^1].end = parseFloat strip e[0]
      total_duration += parseFloat strip e[1].split(':', 1)[1]
  
  let
    n = result.len
    average_duration = if n > 0: total_duration / float n else: 0.0
  info fmt"found {n} silences with {average_duration=}"

proc get_loudness*(f): float =
  ## Scans audio with ebr128 filter and returns I of Integrated loudness.
  # autoscrub-0.7.5/__init__.py:getLoudness()
  let
    lines = if f.major_version > 6: 10 else: 8 # workaround broken '-nostats'
    output = f.exec(
      last = lines,
      options = [
        "-c:v", "copy",
        "-af", "ebur128",
        "-f", "null",
        "-"
      ])
  parseFloat output[^lines].splitWhitespace(3)[1]
