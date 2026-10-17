# BeamNet – tool and plugin for BeamMP server networks

BeamNet has two parts. **`beamnet`** is a command for the server console: it shows the state of all BeamMP servers,
finds problems and fixes them. Its **watcher** reports outages, hanging servers, load, player records, moderation,
new players and milestones to **Discord and Telegram**, posts a network overview every 10 minutes, answers questions in
the Telegram chat (`/heute`, `/woche`, `/teams`, `/saison`, `/spieler` …), picks a **bonus map of the day**, runs scheduled **XP
evenings**, gives update notices, backs up the player data every day and builds a **status page**. **`BeamNetCore`** is a
server plugin shared by all servers: kilometres, driving time, XP and levels, leagues, leaderboards, seasons,
achievements, daily challenges, time trials and group races, jobs (hospital, school, taxi …), chases, convoys, XP
events, teams with a team of the week, `/today`, weekly and season recaps and moderation (bans on all servers, reports, word filter, spam protection) – tested with 64 players and
5000 player files.

## Install

As root on the server console – the second command is a wizard that asks before every step:

```bash
curl -fsSL https://raw.githubusercontent.com/sebastian10099/Agar.io-bot/claude/friendly-goldberg-31l8fp/BeamNet/beamnet.sh \
  -o /usr/local/bin/beamnet && chmod +x /usr/local/bin/beamnet
beamnet setup
```

`beamnet setup` walks through: diagnosis → backup → pausing OpenClaw (if it gets in the way) → repairing and starting
the servers → installing the BeamNetCore plugin → admins → watcher with Discord → status page → restart. Press Enter
to skip a step. Later, `beamnet update` brings the tool and the plugin on all servers up to date (no restart needed;
a new plugin version goes to one test server first and only then to the others).

## Commands

| Command | What it does |
|---|---|
| `beamnet status` | Overview: running?, autostart, who started the process, port, players, map, name |
| `beamnet doctor` | Diagnosis with an explanation and a fix for every problem (changes nothing) |
| `beamnet report` | Report to share: status, diagnosis, plugins and error lines – IP addresses and AuthKeys are masked |
| `beamnet fix` | Stops stray server processes, resets file permissions, sets up log rotation, enables autostart and starts everything cleanly via systemd |
| `beamnet start / stop / restart [nr … \| all]` | Control servers; `stop` and `restart` ask first |
| `beamnet players` | Who is driving right now, per server with names (`players json` = raw data) |
| `beamnet heute` · `woche` · `teams` · `saison` | Same overviews as in the Telegram chat: today's bonuses, weekly best with the weekly goal, teams this week, season standings |
| `beamnet backup` | Saves configurations, plugins and systemd services to `/root/beamnet-backups` |
| `beamnet restore [YYYY-MM-DD]` | Lists the daily data backups or rolls the player data back to one; `beamnet restore <date> spieler <name|id>` restores a single player (no restart); `beamnet restore check` test-restores without writing anything |
| `beamnet install-core` | Installs BeamNetCore on all servers |
| `beamnet watch install` | Sets up the watcher (checks all servers every minute); `status`, `test`, `uninstall` |
| `beamnet web install [port]` | Status page as a website, default port 8080 |
| `beamnet ansage [HH:MM] <text>` | Announcement on all servers, now or at a time of day (without text: list planned ones) |
| `beamnet event start <factor> <duration>` / `stop` / `auto …` | Network-wide XP event; `beamnet event auto fr,sa 20:00 2 2h` runs one automatically, announced an hour before |
| `beamnet slots` | Player slots by popularity: last 30 days per server and more slots for popular servers and maps |
| `beamnet config [<key> <value>]` | Game settings without editing JSON: `beamnet config` lists them (XP per km, jobs, convoy, welcome-back bonus …), `beamnet config comebackXp 100` changes one, `beamnet config aufgaben km speed jobs mapkm bonus` picks the daily challenges (`bonus` = drive on the bonus map); checked and applied within a minute |
| `beamnet update` | Updates the tool **and** the plugin on all servers |

Add `-y` to run a command without questions. Day names for `beamnet event auto` are German: `mo di mi do fr sa so`
or `täglich`.

## Watcher

Configured in `/etc/beamnet.conf` (Discord webhook and/or Telegram bot), tested with `beamnet watch test`.

- Reports outages and recoveries once each („🔴 Server 5 (utah) ist ausgefallen“ / „🟢 … ist wieder online“); with
  `AUTO_RESTART=1` it restarts failed servers (at most 3 times per hour).
- Detects **hanging servers**: the service runs but BeamNetCore has not reported for 3 minutes (`HANG_MIN`).
- Watches the **load** per server (CPU and RAM) and warns once, with an all-clear.
- **Network overview** every 10 minutes while someone plays (`NETWORK_REPORT`): players per server (account players by
  name, guests counted), empty servers and how full each map is.
- Remembers the **player record** (most players at the same time) and reports new records.
- **Backs up the player data every day** (`/root/beamnet-backups/daten-<date>.tgz`, 14 days) and test-restores the
  newest backup once a week.
- Reports moderation (bans, kicks, mutes, warnings), in-game reports, league promotions and new track records; posts
  weekly and season winners (with the team of the week) and a daily summary (with the next XP evening).
- Map rotation, map votes from the chat and automatic player slots (only while a server is empty).
- The Telegram bot answers `/online`, `/top`, `/rekord`, `/server`, `/event` (XP event running? next XP evening?) and
  `/spieler <name>` (level, league, XP, rank, kilometres, jobs of a player) and `/plaetze` (slot usage of the last 30
  days and where the automatic slots will add more) and `/woche` (top 5 of the calendar week by kilometres and the
  community weekly goal) and `/heute` (daily challenge, XP event, bonus map, next XP evening and weekly goal at a
  glance), `/teams` (teams by kilometres this week) and `/saison` (top 5 of the running season, the leading team and
  last season's winners) in the configured chat. The watcher registers this command list with Telegram itself (once
  per version), so Telegram suggests the commands when you type "/". Accounts listed in
  `TELEGRAM_ADMINS` may also send `/ansage [HH:MM] <text>` (announcement on all servers) and `/event 2 2h` /
  `/event stop`.
- **XP evenings:** `beamnet event auto fr,sa 20:00 2 2h` starts double XP on all servers every Friday and Saturday at
  20:00 for two hours, announced an hour before (Discord/Telegram and in game). Players see the next one with `/event`
  and on the status page under "Demnächst".
- **Bonus map of the day:** the map driven least in the last 7 days gets +50 % XP while driving until midnight
  (announced on Discord/Telegram, in game at join and with `/event`), so players spread over the servers. If a map
  rotation or vote moves it off every server, a new one is picked right away. It is also shown on the status page
  under "Demnächst", in the network overview ("⭐ Bonus"), with `beamnet event` and with `/event` in Telegram;
  in game, `/server` marks the servers running it (⭐). `BONUS_MAP=0` turns it off,
  `BONUS_MAP_FACTOR=1.5` (up to 3) changes the bonus.
- **Milestones:** level 25/50/75/100 and 1,000/5,000/10,000/25,000 km of a player, league promotions and new players;
  `MILESTONE_NOTIFY=0` turns these off, `MODLOG_NOTIFY=0` only the moderation reports.
- **Update notice:** once a day it checks GitHub for a newer BeamNet and reports it once per version ("🆕 BeamNet-Update
  verfügbar … sudo beamnet update"). It never installs anything itself; `UPDATE_CHECK=0` turns it off.
- It never fights you: servers stopped with `beamnet stop` count as maintenance until `beamnet start`.

## In-game chat commands

Every player can switch to English with `/lang en`; the German commands work too.

| Command | Answer |
|---|---|
| `/help` | List of commands |
| `/stats [name]` | Level, league, XP, kilometres, driving time, top speed, rank, XP to the next level |
| `/top [km \| xp \| speed \| jobs \| convoy \| chase \| week \| teams]` | Leaderboard (top 5); `teams` = teams this week |
| `/league` | All leagues and how far it is to the next one |
| `/season` | Season table (calendar month), leading team, your place and the gap to the next one, last season's winners |
| `/server` | All BeamNet servers with map and player count (switch servers in the BeamMP launcher) |
| `/where <name>` | Which server is a friend on right now? |
| `/km` | Your kilometres |
| `/race [name]` | Tracks of this map with records, track of the week; `/race <name>` starts a time trial |
| `/records [name]` | Top 5 of a track or the records of all tracks on this map |
| `/achievements [name]` | Unlocked achievements and the next ones with progress |
| `/daily` | Daily challenge and progress |
| `/today` | Everything for today at a glance: daily challenge, XP event or next XP evening, bonus map, streak, weekly goal |
| `/vote map <name>` | Start a vote for another map (`/vote yes`, `/vote no`) |
| `/event` | Is an XP event running? (admins: `/event <factor> <duration>`) |
| `/report <name> <reason>` | Report a player to the admins |
| `/rules` | The rules of the network |
| `/lang en` | English (`/lang de` = German) |
| `/job` | Driving job: take a patient to the hospital, children to school, a taxi guest to the station … Without places on a map, jobs go to drop-off points where players have driven; hints show the direction. Several jobs in a row (a "shift") give bonus XP |
| `/goal` | Weekly goal for everyone: collect kilometres together, everyone who drives gets bonus XP |
| `/chase` | Chase: one player flees, everyone else hunts them |
| `/convoy` | Convoy bonus: drive close to other players for bonus XP; shows who is nearby |
| `/duel <name> <track>` | Challenge a player to a time trial |
| `/series [name]` | Race series: several tracks in a row, the times add up |
| `/friend <name>` | Friend list: get a message when a friend comes online anywhere in the network |
| `/team` | Teams: `/team create <name>`, `/team join <name>`, `/team leave`, `/team list` (all-time ranking), `/team week` (this week; also `/top teams`). Members count from the week after they join. Every Monday the **team of the week** is announced; members who drove at least 5 km get +50 XP once. At month end the **team of the season** is announced. Teammates coming online are announced like friends |
| `/places` | Places (hospital, school, fire station …) on this map |
| `/start` | Starter path for new players with bonus XP |

Players who come back after at least 14 days get a one-time welcome-back bonus (+50 XP). On the first visit of a new
week, players see their kilometres and rank of the last week; on the first visit of a new month, their season recap.

German documentation: README.md
