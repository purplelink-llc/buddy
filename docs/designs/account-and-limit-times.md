# Account tag and usual limit times

## Account tag

A line under the usage rows names the Claude app's signed-in account. Buddy reads `lastKnownAccountUuid` from
`~/Library/Application Support/Claude/config.json`. It gives each account the name of its folder in `~/.claude-accounts/`,
where the account switcher saves accounts. Unknown accounts fall back to the part of the email before the @, or a short id.

Exact usage reads Claude Code's own sign-in (`oauthAccount` in `~/.claude.json`), not the app's. When exact usage is on
and the two differ, the line turns orange and says which account the numbers belong to.

Buddy only reads these files. It never signs in or out, and never switches accounts.

## Usual limit times

Buddy keeps four weeks of session-limit hits in `~/Library/Application Support/Buddy/limits.json` (mode 600).
- **Sources:** live hits come from the usage scanner. On first run, a one-time pass reads older transcripts for
  `rate_limit` lines. Weekly limits are skipped.
- **Merging:** a hit before an earlier hit's reset time is the same limit (a retry, or another chat stopping), so only the first counts. Hits less than 10 minutes apart also count as one.
- **Account:** a hit seen within 15 minutes is tagged with the app's account at that moment. Backfilled hits carry no
  account, and they count for every account.

A time of day is "usual" when hits fell within an hour of it on at least three different days, and on at least a quarter of the days that had any limit (so someone who runs out at all hours gets no usual time). The time shown is the
average of those hits, rounded to 5 minutes. A cluster that spans midnight is handled.

The heads-up is opt-in (Settings → Pace). It sends one notification up to an hour before a usual time, and only when:
- the session is at least 40% used,
- the session is not yet at 100%, and
- no chat is paused by a limit.

Each usual time is warned about once.
