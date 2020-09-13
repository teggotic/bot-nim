import ws, asyncdispatch
import strformat, strutils
import threadpool
import regex
import tables

type
  WSChan = ptr Channel[string]

  TwitchConfig = ref object
    chat_oauth : string
    chat_nickname : string
    channels : seq[string]

  TwitchBot* = object
    chanFromWS : WSChan
    chanToWS : WSChan
    conf : TwitchConfig

const
  PING_REGEX   = re"PING (?P<content>.+)"
  DATA_REGEX   = re"^(?:@(?P<tags>\S+)\s)?:(?P<data>\S+)(?:\s)(?P<action>[A-Z()-]+)(?:\s#)(?P<channel>\S+)(?:\s(?::)?(?P<content>.+))?"
  AUTHOR_REGEX = re"(?P<author>[a-zA-Z0-9_]+)!(?P<author>[a-zA-Z0-9_]+)@(?P<author>[a-zA-Z0-9_]+).tmi.twitch.tv"
  GROUPS       = @["action", "data", "content", "channel", "author"]


proc send(bot: TwitchBot, msg: string) =
  bot.chanToWS[].send(msg)

proc finish*(bot: TwitchBot) =
  bot.chanFromWS[].close()

proc startProcessing(bot: TwitchBot) =
  proc processAction() =
    let 
      action = groups["action"]? || "PING"
      data = groups["data"]?
      content = groups["content"]?.try(&.strip)
      channel_name = groups["channel"]?
      author = AUTHOR_REGEX.match(data).try(&.["author"]?) if data
      channel = get_channel(channel_name) if channel_name
      message = TwitchMessage.new(author, content, msg, channel) if author && content && msg && channel

    if action == "RECONNECT"
      # TODO Disconnection/Reconnection Logic.
      return
    elsif action == "JOIN"
    elsif action == "PART"
    elsif action == "PING"
      process_ping(content)
    elsif action == "PRIVMSG"
      event_message(message) if message
    end

  proc processData(data: string) =
    let data = data.strip()
    echo data
    var
      match: Regex
    if data.startsWith("PING"):
      match = PING_REGEX
    else:
      match = DATA_REGEX

    var matchData: RegexMatch
    let result = data.match(match, matchData)

    if not result:
      return

    let groups = newTable[string, string]()

    for g in GROUPS:
      if g in matchData.groupNames:
        let m = matchData.groupFirstCapture(g, data)
        groups[g] = m

    echo $groups


  proc waitForMsg(chanFromWS: WSChan) =
    while true:
      spawn processData chanFromWS[].recv()

  spawn waitForMsg(bot.chanFromWS)

proc runWS(bot: TwitchBot) =
  proc processWs(chanToWS: WSChan, chanFromWS: WSChan) =
    var ws = waitFor newWebSocket("ws://irc-ws.chat.twitch.tv:80")
    # var ws = waitFor newWebSocket("ws://localhost:5678")
    echo "Connected"

    proc writeWS() {.async.} =
      while true:
        let tried = chanToWS[].tryRecv()
        if tried.dataAvailable:
          await ws.send tried.msg
        await sleepAsync(0)

    proc readWS() {.async.} =
      while true:
        let msg = await ws.receiveStrPacket()
        chanFromWS[].send msg

    asyncCheck readWS()
    asyncCheck writeWS()

    runForever()

  spawn processWs(bot.chanToWS, bot.chanFromWS)

proc authenticate(bot: TwitchBot) =
  bot.send(fmt"PASS {bot.conf.chat_oauth}")
  bot.send(fmt"NICK {bot.conf.chat_nickname}")

  for chan in bot.conf.channels:
    bot.send(fmt"JOIN #{chan}")
proc newBot*(chat_oauth: string, chat_nickname: string, channels: seq[string] = @[]): TwitchBot =
  var
    bot: TwitchBot

  bot.chanFromWS = cast[WSChan](
    allocShared0(sizeof(Channel[string]))
  )
  bot.chanToWS = cast[WSChan](
    allocShared0(sizeof(Channel[string]))
  )
  bot.conf = TwitchConfig(
    channels: channels,
    chat_nickname: chat_nickname,
    chat_oauth: chat_oauth,
  )

  return bot

proc run*(bot: TwitchBot) =
  bot.chanFromWS[].open()
  bot.chanToWS[].open()

  bot.runWS
  bot.startProcessing

  bot.authenticate()

  sync()
