# nimbu
# Copyright (c) 2026 Agnish Ghosh
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

## Logging setup, adapted from nimbus-eth2's `nimbus_binary_common.nim`.
## Binaries are built with `chronicles_sinks=textlines[dynamic],json[dynamic]`
## (see nimbu/nimbu.nim.cfg): output 0 is text, output 1 is JSON.

import
  std/[os, strutils, terminal],
  chronicles, chronicles/[helpers, topics_registry], results

const dynamicSinks =
  when compiles(defaultChroniclesStream.outputs.type.arity):
    defaultChroniclesStream.outputs.type.arity == 2
  else:
    false # logging compiled out, e.g. silent test builds

when dynamicSinks:
  import stew/staticfor

export chronicles, results

type
  StdoutLogKind* {.pure.} = enum
    Auto = "auto"
    Colors = "colors"
    NoColors = "nocolors"
    Json = "json"

proc updateLogLevel*(logLevel: string) {.raises: [ValueError].} =
  ## Accepts `LEVEL` or `LEVEL;LEVEL:topic1,topic2;...`, e.g.
  ## `INFO;DEBUG:chain,builder`
  let directives = logLevel.split(";")
  try:
    setLogLevel(parseEnum[LogLevel](directives[0].toUpperAscii()))
  except ValueError:
    raise (ref ValueError)(msg:
      "Invalid log level '" & directives[0] &
      "': use one of TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL")

  if directives.len > 1:
    for topicName, settings in parseTopicDirectives(directives[1..^1]):
      if not setTopicState(topicName, settings.state, settings.logLevel):
        warn "Unrecognized logging topic", topic = topicName

proc detectTTY*(format: StdoutLogKind): StdoutLogKind =
  if format != StdoutLogKind.Auto:
    return format
  if getEnv("NO_COLOR").len == 0 and isatty(stdout):
    StdoutLogKind.Colors
  else:
    StdoutLogKind.NoColors

proc setupLogging*(
    logLevel: string, format: StdoutLogKind): Result[void, string] =
  when dynamicSinks:
    proc noOutput(logLevel: LogLevel, msg: LogOutputStr) = discard
    proc stdoutFlush(logLevel: LogLevel, msg: LogOutputStr) =
      try:
        stdout.write(msg)
        stdout.flushFile()
      except IOError:
        discard # nowhere left to report it

    case detectTTY(format)
    of StdoutLogKind.Auto:
      raiseAssert "resolved by detectTTY"
    of StdoutLogKind.Colors:
      defaultChroniclesStream.outputs[0].writer = stdoutFlush
      defaultChroniclesStream.outputs[0].colors = true
      defaultChroniclesStream.outputs[1].writer = noOutput
    of StdoutLogKind.NoColors:
      defaultChroniclesStream.outputs[0].writer = stdoutFlush
      defaultChroniclesStream.outputs[0].colors = false
      defaultChroniclesStream.outputs[1].writer = noOutput
    of StdoutLogKind.Json:
      defaultChroniclesStream.outputs[0].writer = noOutput
      defaultChroniclesStream.outputs[1].writer = stdoutFlush

    staticFor i, 0 ..< defaultChroniclesStream.outputs.type.arity:
      setLogEnabled(defaultChroniclesStream.outputs[i].writer != noOutput, i)
  else:
    # e.g. tests built with a fixed or no sink: only the level can be changed
    discard format

  try:
    updateLogLevel(logLevel)
  except ValueError as exc:
    return err(exc.msg)
  ok()
