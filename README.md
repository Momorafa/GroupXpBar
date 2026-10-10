# Group XP Bar

A small World of Warcraft (Forever) addon that shows an experience bar for every member of your group: name in class colour, level and percentage through the level. Hover a bar for exact XP and XP to next level.

Members share their XP through hidden addon messages, so a member's bar fills only if they run **Group XP Bar** or **Naowh Forever** (the message format is compatible with Naowh's Group XP). Members without either show their level and "no addon".

## Install

1. Download this repository (Code → Download ZIP).
2. Extract it into `World of Warcraft\_classic_beta_\Interface\AddOns\`.
3. Rename the folder to exactly `GroupXpBar` (GitHub adds `-main` to the name).
4. Restart the game or `/reload`.

## Commands

| Command | What it does |
| --- | --- |
| `/gxp unlock` | Show sample bars and drag them where you want |
| `/gxp lock` | Lock them in place |
| `/gxp self` | Show or hide your own bar |
| `/gxp width <160-500>` | Bar width |
| `/gxp scale <0.5-2>` | Overall size |
| `/gxp alpha <0-1>` | Background opacity |
| `/gxp test` | Preview with sample members |
| `/gxp reset` | Restore defaults |
| `/gxp debug` | Print what is sent and received, for troubleshooting |

The bars only appear while you are in a group. Updates are held during combat and sent when it ends.
