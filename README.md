# BetterQuestTracker

A quest tracker for the World of Warcraft Forever beta, which runs the Retail
addon API. It replaces Blizzard's objective tracker with one that shows the
quests for the zone you are in, nearest first.

## Install

Put this folder in `_classic_beta_/Interface/AddOns/BetterQuestTracker` and
restart the game. A `/reload` does not pick up changes to the `.toc` file.

## What it does

- Shows quests for your current zone, grouped under the zone headers from your
  quest log. Click the filter icon in the header to show all quests and back;
  it turns grey while all quests show.
- Sorts quests by distance, nearest first. The tracker checks every 2 seconds
  and only redraws when the order changes. Optionally, quests that are ready
  to turn in move to the bottom of their zone (off by default).
- Follows the checkboxes in the quest log. Uncheck a quest there and it leaves
  the tracker.
- Optionally unchecks newly accepted quests that are 3 or more levels above
  you. This is off by default; turn it on in the settings, where the threshold
  is configurable too. When you level up, or turn the option off, the
  addon checks those quests again. While the option is on, the skull icon in
  the header shows or hides those quests in the tracker; it turns grey while
  they show.
- Adds a button left of each quest that has a usable quest item. The button
  shows the item's cooldown and charges.
- Shows a tooltip on hover with the quest text, objective progress, and the
  progress of party members.
- Colours the quest level by difficulty, the same way the quest log does.
- Lists recipes you track in the profession window below your quests, with
  each reagent as "in bags/needed", green once you carry enough. Turn it off
  in the settings.

Blizzard's tracker stays hidden while the addon is loaded. Disable the addon to
get it back.

When the durability figure (the armor icon that appears when gear is damaged)
overlaps the locked tracker, the tracker moves down below it and returns once
the figure hides. The saved position does not change.

## Mouse

On a quest:

| Click        | Action                                                   |
| ------------ | -------------------------------------------------------- |
| Left         | Set or remove the waypoint arrow                         |
| Shift + left | Remove from the tracker, or link it while typing in chat |
| Ctrl + left  | Open the quest in the quest log                          |
| Right        | Quest options: waypoint, share, remove, abandon          |
| Middle       | Collapse or expand the quest's objectives                |

On a zone heading, middle-click collapses or expands the whole zone.

On a recipe, left-click opens it in the profession window, shift-click
removes it from the tracker, and right-click shows the recipe options.

In the header, from left to right: the padlock unlocks the tracker, the skull
shows or hides high-level quests (only while that option is on), and the filter
switches the zone filter. The padlock only shows while the mouse is over the
header; the skull stays visible while it hides high-level quests and only
shows on hover while they are showing. The button just outside the tracker's
top-right corner collapses or expands it.

With the tracker unlocked, the padlock stays lit, drag the tracker to move it,
and use the mouse wheel to scale it. The current scale shows as a percentage,
and right-click resets it to 100% without moving the tracker.

With the tracker locked, the mouse wheel scrolls the list once it is taller
than the maximum height.

## Commands

| Command           | Action                                       |
| ----------------- | -------------------------------------------- |
| `/bqt`            | Open the settings panel                      |
| `/bqt move`       | Lock or unlock the tracker                   |
| `/bqt scale <n>`  | Set the scale, 0.5 to 2.5                    |
| `/bqt width <n>`  | Set the width, 150 to 600                    |
| `/bqt height <n>` | Set the height before scrolling, 150 to 1200 |
| `/bqt zone`       | Toggle the zone filter                       |
| `/bqt sort`       | Toggle sorting by distance                   |
| `/bqt watch`      | Toggle following the quest log checkboxes    |
| `/bqt quiet`      | Mute the addon's automatic chat messages     |
| `/bqt reset`      | Reset position, scale, width and height      |
| `/bqt perf`       | Print memory and CPU usage                   |
| `/bqt layout`     | Print tracker and durability positions       |
| `/bqt help`       | List the commands                            |

The settings panel lives under Options > AddOns > BetterQuestTracker.

## Saved data

`BetterQuestTrackerDB` holds account-wide settings: layout, filters and
collapsed zones. `BetterQuestTrackerCharDB` holds per-character data: the
quests the addon unchecked and the quests you collapsed.

## Combat

Quest item buttons use secure action buttons. The game does not let addons
move, show or hide those during combat, so the buttons keep their position
until combat ends and then realign. They still work during combat.

## Performance

The addon has no `OnUpdate` handlers. Quest log events are batched into one
redraw per 0.25 seconds. Memory sits around 100 to 250 KB after garbage
collection; the number in `/bqt perf` climbs between collections because the
quest log API returns new tables on every call.
