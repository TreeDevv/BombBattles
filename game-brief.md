# Bomb Battles Game Brief

## Working Title And Intent

**Bomb Battles** is the working Roblox project name. The game design is a team-based destruction arena inspired by Minecraft-style **Bomb Lobbers**.

Players throw arcing bombs across destructible floating arenas to damage terrain, eliminate enemies, and destroy enemy **respawn anchors**. In code and early implementation notes, these anchors may also be called **base cores** or **TeamCore** instances, but the design-facing term is respawn anchor.

## Game Overview

Bomb Battles is a fast-paced 6v6 max team arena game where two teams fight from separate island bases. Players are not permanently removed the first time they die. A team can keep respawning while at least one of its respawn anchors remains active.

Victory comes from destroying every enemy respawn anchor, then eliminating all remaining enemy players. This makes each match progress from chaotic team artillery combat into a tense last-team-standing endgame once respawns are disabled.

Target match length is **5-8 minutes**, adjusted by map size, player count, terrain durability, anchor count, and bomb pressure.

## Core Fantasy

Players are chaotic artillery fighters in a bright, readable destruction arena. Every throw should feel exciting: bombs arc through the air, land with clear danger, explode with satisfying impact, break the arena apart, and force players to move, aim, recover, and react under pressure.

The fantasy is simple team chaos with objective pressure: protect your anchors, break enemy anchors, survive the collapsing map, and make clutch throws when respawns are gone.

## Design Pillars

- **Destruction:** The map changes constantly as bombs create holes, remove cover, open pathways, and shrink safe space.
- **Objective pressure:** Teams must choose between defending anchors, attacking enemy anchors, and fighting players.
- **Readable danger:** Bomb arcs, landing zones, fuses, and explosions must be clear enough to dodge and counterplay.
- **Smooth mobility:** Dodging, jumping, landing, recovery, knockback, and repositioning should feel responsive and fair.
- **Comebacks:** A team can lose players but recover while anchors remain active.
- **Escalation:** Matches should naturally move from broad team fights to a high-tension final elimination phase.
- **Accessibility:** The core controls are easy to understand: throw bombs, use an offensive ability, use a defensive ability, and survive.

## Core Match Structure

- **Team size:** Up to 6v6, adjustable based on player count.
- **Objective:** Destroy all enemy respawn anchors and eliminate all remaining enemy players.
- **Small maps:** 2 respawn anchors per team.
- **Large maps:** 3 respawn anchors per team.
- **Player health:** 100 HP.
- **Falling off the map:** Instant death. Normal respawn rules still apply.
- **Respawn delay:** 5 seconds while the player's team has at least one active anchor.
- **No-anchor state:** Players who die after their team has 0 active anchors are permanently eliminated for the round.

## Health And Damage

Players should feel vulnerable but not instantly deleted.

- **Direct bomb hit:** 50 damage.
- **Near explosion:** 25-35 damage.
- **Outer radius:** 10-20 damage.

This creates a baseline where 2 perfect hits eliminate a player, while most fights take around 3 average hits.

Respawn anchors are tougher objectives:

- Each anchor requires roughly **5 direct bomb hits** to destroy.
- Indirect splash damage affects anchors at reduced effectiveness.
- Players must commit to objective attacks instead of passively breaking anchors through stray splash.

## Bomb System

Bombs are the primary weapon and the main source of terrain destruction.

- **Maximum inventory:** 5 bombs.
- **Recharge rate:** 1 bomb every 2 seconds.
- **Behavior:** Bombs arc through the air, land, detonate after a short fuse, damage players, damage terrain, and damage anchors.

The inventory cap prevents spam while the recharge rate keeps players in the action.

## Terrain Destruction

Terrain destruction is a core pillar, not a visual-only effect.

Bombs should:

- Create holes.
- Remove cover.
- Open new pathways.
- Create fall hazards.
- Make movement harder as the match progresses.
- Reduce safe space over time.

Early maps can start with simple destructible island chunks, but the goal is for each match to visibly degrade from stable arena to dangerous final battlefield.

## Movement Feel

Movement should be smooth, responsive, and slightly more polished than default Roblox movement while staying easy to read in combat. Players should be able to dodge incoming bombs, recover from close explosions, reposition for throws, and make clutch escapes without the controls feeling slippery or overly complex.

The first movement pass should focus on feel, not advanced parkour. Good acceleration, air control, jump timing, landing feedback, and readable knockback recovery matter more than adding many movement abilities. Any extra movement tools should support the core bomb-dodging loop.

## Ability System

Each player equips one **offensive ability** and one **defensive ability** before the match. Abilities add expression and highlight moments, but they should stay balanced against standard bomb play.

Offensive ability examples:

- **Cluster Bomb:** Splits into multiple explosions. 20s cooldown.
- **Sticky Bomb:** Attaches to surfaces and players. 18s cooldown.
- **Black Hole Bomb:** Pulls nearby enemies before detonating. 25s cooldown.
- **Airstrike:** Marks an area for bombardment. 30s cooldown.
- **Knockback Blast:** Large displacement, low damage. 15s cooldown.
- **Drill Bomb:** Burrows through terrain before exploding. 22s cooldown.

Defensive ability examples:

- **Wall Builder:** Creates destructible cover. 20s cooldown.
- **Forcefield:** Temporarily blocks explosions. 25s cooldown.
- **Emergency Platform:** Creates a small platform beneath the player. 18s cooldown.
- **Reinforced Ground:** Temporarily strengthens nearby terrain. 25s cooldown.
- **Dash:** Quick movement burst. 12s cooldown.
- **Grapple Hook:** Recovery and repositioning tool. 15s cooldown.

## Core Gameplay Loop

1. Players enter a lobby or intermission.
2. Players are assigned to teams.
3. Each team spawns on its own island with active respawn anchors.
4. Players begin with or recharge into a limited bomb inventory.
5. Players throw bombs to damage terrain, enemies, and anchors.
6. Players defend friendly anchors while pressuring enemy anchors.
7. Dead players respawn after 5 seconds while their team has at least one active anchor.
8. Destroying every enemy anchor disables that team's respawns.
9. The match becomes last-team-standing once a team has no anchors.
10. A team wins when the enemy team has no active anchors and no surviving players.
11. The arena resets and the loop begins again.

## Match Flow

- **Intermission:** Players gather, choose or confirm loadouts, and wait for team assignment.
- **Team assignment:** Players are split into opposing teams.
- **Island spawn:** Teams spawn on separate islands with anchors, cover, and room to dodge.
- **Early game:** Teams skirmish, defend anchors, probe enemy positions, and fight on mostly intact terrain.
- **Mid game:** Some anchors are destroyed, terrain is heavily damaged, and teams make more aggressive pushes.
- **End game:** Respawns are disabled for one or both teams, safe terrain is limited, and the round becomes high-tension elimination.
- **Win state:** The last team with surviving players after enemy anchors are destroyed wins.
- **Reset:** The arena resets quickly so the next match can start.

## Player Objective

The player's objective is to help their team destroy the opposing respawn anchors, then eliminate the opposing team by throwing bombs accurately, dodging enemy bombs, protecting friendly anchors, using abilities at the right time, and surviving the collapsing arena.

The team objective is simple: protect your anchors, break the enemy anchors, then be the last team standing.

## Progression And Monetization

Progression should be cosmetic-focused. Purchased or premium systems must not create gameplay advantages.

Players earn coins through gameplay and can use currency to open crates. Premium currency can open the same crates.

Cosmetic reward examples:

- Bomb skins: TNT, Cannonball, Meteor, Ice Bomb, Void Bomb, Disco Bomb, Nuclear Core.
- Titles.
- Trails, victory effects, and other player expression cosmetics.

Daily spin wheel:

- One free spin daily.
- Additional spins may be earned through play.
- Possible rewards include coins, bomb skins, titles, premium currency, and ability variants.

Rare ability unlock examples:

- Meteor Strike.
- Time Bubble.
- Gravity Well.
- Orbital Laser.

Rare abilities should offer unique playstyles while remaining balanced with standard abilities.

## MVP Scope

The first playable version should prove the core match before adding the full progression and ability suite:

- One arena with two opposing islands.
- Two teams.
- Basic bomb throwing with arc, fuse, explosion, damage, and knockback.
- Limited bomb inventory and recharge.
- Smooth player movement tuned for dodging and recovery.
- Respawn anchors that gate team respawns.
- Player death, 5-second respawn delay, and permanent elimination after anchor loss.
- Basic terrain destruction.
- Falling death with normal respawn rules.
- Round start, active round, win condition, and reset.
- Simple UI for round state, team status, anchor status, bomb count, and winner announcement.

## Future Expansion Ideas

- Full offensive and defensive ability loadouts.
- More bomb behaviors and cosmetic bomb skins.
- Multiple arenas with different anchor counts and terrain layouts.
- Stronger terrain material rules, reinforced ground, and map-specific hazards.
- Powerups or temporary map events.
- Daily spin wheel, crates, titles, and cosmetic progression.
- Rare balanced ability variants.
- Spectating for eliminated players.
- Casual and competitive queue variants.

## Current Direction

Bomb Battles should start as a readable, team-based destruction arena with respawn anchors as the central objective. The first goal is to make throwing bombs, dodging explosions, breaking anchors, respawning, and surviving the endgame feel good. Everything else should build on that foundation.
