#!/usr/bin/env python3
# Authors the entire Overland world as data -> world.json (a mode:"chunk" grid the Godot runtime
# streams). Three districts joined by rolling countryside. Run from the repo root:  python3 tools/gen_world.py
import json, random

BUILD_ID = "cloud-uhd0t0dyh3pylvbcsftn"   # where the two Meshy-generated .glb (fountain, hero) are staged on R2
CARS = ["props/kk_city/car_sedan.glb", "props/kk_city/car_taxi.glb",
        "props/kk_city/car_hatchback.glb", "props/kk_city/car_stationwagon.glb"]
# CITY crowds: neutral hooded/casual figures only (no wizard hats / armor / bows) so the modern
# downtown reads cohesive next to the hoodie-wearing hero. TOWN crowds keep the varied set.
CITY_CROWD = ["characters/kk_Rogue.glb", "characters/kk_Rogue_Hooded.glb"]
TOWN_CROWD = ["characters/kk_Rogue_Hooded.glb", "characters/kk_Mage.glb", "characters/kk_Knight.glb"]
TREES = ["props/q_unature/CommonTree_1.glb", "props/q_unature/CommonTree_3.glb",
         "props/q_unature/CommonTree_5.glb", "props/q_unature/BirchTree_2.glb", "props/q_unature/BirchTree_4.glb"]
BUSHES = ["props/kk_nature/Bush_1_A_Color1.glb", "props/kk_nature/Bush_2_A_Color1.glb", "props/kk_nature/Bush_1_D_Color1.glb"]
STREETLIGHT = "props/q_street/Streetlight_Single.glb"
BENCH = "props/kk_city/bench.glb"

cells = []


def rng(gx, gz):
    return random.Random(gx * 928371 + gz * 12379 + 7)


def find_cell(gx, gz):
    for c in cells:
        if c["cell"] == [gx, gz]:
            return c
    return None


# ---- DOWNTOWN: gx -2..2, gz -2..2 (glass towers, cross-road grid, traffic, crowds) ----
TOWER_MATS = ["glass", "glass", "steel", "concrete", "glass"]
for gz in range(-2, 3):
    for gx in range(-2, 3):
        r = rng(gx, gz)
        cell = {"cell": [gx, gz], "ground": "asphalt",
                "roads": [{"dir": "x", "width": 7}],
                "traffic": {"set": CARS, "count": 2, "speed": 8.0},
                "populate": [{"set": CITY_CROWD, "count": 3, "vary": True, "behaviour": "wander",
                              "rig": "kaykit", "radius": 7.5, "speed": 1.3}]}
        structs = []
        corners = [(-7, -7), (7, -7), (-7, 7), (7, 7)]
        r.shuffle(corners)
        if gx == 0 and gz == 0:   # spawn cell keeps a central civic monument instead of a tower cluster
            structs.append({"pos": [0, 0], "footprint": [3.2, 3.2], "height": 16.0,
                            "profile": "taper", "batter": 0.6, "cap": "pyramidion", "roof_height": 4.0,
                            "material": "limestone", "roof_material": "steel", "collider": "box"})
            ntow = 2
        else:
            ntow = r.choice([2, 3, 3])
        for i in range(ntow):
            cx, cz = corners[i]
            prof = r.choice(["vertical", "vertical", "setback"])
            fp = r.choice([6.0, 6.5, 7.0])
            t = {"pos": [cx, cz], "footprint": [fp, fp], "floors": r.randint(6, 16),
                 "floor_height": 3.4, "profile": prof, "cap": "flat", "material": r.choice(TOWER_MATS),
                 "facade": {"type": "windows", "glow": [1.0, 0.9, 0.65], "lit": 1.9}, "collider": "box"}
            if prof == "setback":
                t["steps"] = 3
                t["shrink"] = 0.8
            structs.append(t)
        cell["structures"] = structs
        cell["props"] = [{"url": STREETLIGHT, "pos": [3.0, 3.0], "sound": "crowd"},
                         {"url": STREETLIGHT, "pos": [-3.0, -3.0]},
                         {"url": BENCH, "pos": [-3.2, 6.5]}]
        cells.append(cell)

find_cell(1, 0)["npc"] = {"id": "mira", "name": "Mira", "pos": [6, -6], "model": "characters/kk_Rogue_Hooded.glb",
    "persona": "You are Mira, an upbeat downtown tour guide in a bustling modern city of glass towers. You love the traffic, the crowds, the neon at night. Answer the traveler warmly in ONE short sentence, and if it fits, point them north up the tree-lined boulevard to the old town.",
    "lines": ["Mira: Welcome to Downtown! Glass towers, traffic, the whole buzz.",
              "Mira: Head north up the boulevard and you'll reach the old town."]}
find_cell(-1, 1)["npc"] = {"id": "jonah", "name": "Jonah", "pos": [-6, 6], "model": "characters/kk_Rogue.glb",
    "persona": "You are Jonah, a friendly street-food vendor on a downtown corner. Cheerful, a little sales-y. Answer in ONE short sentence.",
    "lines": ["Jonah: Fresh from the cart! Best lunch in the district.",
              "Jonah: You can drive across the whole world, you know - grab that car."]}

# ---- COUNTRYSIDE + BOULEVARD: gx -2..2, gz 3..9 ----
for gz in range(3, 10):
    for gx in range(-2, 3):
        r = rng(gx, gz)
        if gx == 0:   # the tree-lined boulevard: grass verge + a central NS road + tree rows + light traffic
            cell = {"cell": [gx, gz], "ground": "grass",
                    "roads": [{"dir": "ns", "width": 8}],
                    "traffic": {"set": CARS, "count": 2, "speed": 9.0},
                    "rows": [{"from": [-7, -10], "to": [-7, 10], "spacing": 6.0, "part": {"url": TREES[0]}},
                             {"from": [7, -10], "to": [7, 10], "spacing": 6.0, "part": {"url": TREES[3]}}],
                    "populate": [{"set": CITY_CROWD, "count": 2, "vary": True, "behaviour": "wander",
                                  "rig": "kaykit", "radius": 6.0, "speed": 1.2}]}
        else:   # open rolling countryside: dense tree/bush scatter
            cell = {"cell": [gx, gz], "ground": ("grass" if r.random() < 0.6 else "dirt"),
                    "scatter": [{"url": r.choice(TREES), "count": r.randint(9, 14)},
                                {"url": r.choice(TREES), "count": r.randint(6, 10)},
                                {"url": r.choice(BUSHES), "count": r.randint(6, 10)}]}
            if r.random() < 0.4:
                cell["populate"] = [{"set": CITY_CROWD, "count": 1, "vary": True,
                                     "behaviour": "wander", "rig": "kaykit", "radius": 6.0, "speed": 1.1}]
        cells.append(cell)

find_cell(1, 6)["npc"] = {"id": "rell", "name": "Rell", "pos": [0, 0], "model": "characters/kk_Rogue.glb",
    "persona": "You are Rell, a laid-back wanderer resting in the rolling countryside between the city and the old town. Calm, a little poetic about the hills and the open road. Answer in ONE short sentence.",
    "lines": ["Rell: Nice out here, isn't it? The hills just keep rolling.",
              "Rell: City's behind you, the old town's over the rise ahead."]}
find_cell(-1, 5)["props"] = [{"url": TREES[2], "pos": [0, 0], "sound": "country"}]
find_cell(2, 8)["props"] = [{"url": TREES[1], "pos": [2, -2], "sound": "birds"}]


# ---- OLD-TOWN: gx -2..2, gz 10..13 (timber houses, radial fountain plaza) ----
def timber_house(r):
    return {"structure": {"footprint": [r.choice([6.0, 7.0, 7.5]), r.choice([5.0, 6.0, 6.5])],
            "floors": r.choice([1, 2]), "floor_height": 3.0, "profile": "vertical",
            "cap": r.choice(["gable", "hip"]), "roof_height": 3.0,
            "material": r.choice(["timber", "wood", "stucco"]), "roof_material": "roof_tile",
            "rot": r.choice([0, 90, 180, 270]), "collider": "box"}}


for gz in range(10, 14):
    for gx in range(-2, 3):
        r = rng(gx, gz)
        if gx == 0 and gz == 12:   # THE PLAZA: sandstone, Meshy fountain centre, a radial RING of timber houses
            cell = {"cell": [gx, gz], "ground": "sandstone",
                    "landmark": {"url": "/%s/models/fountain.glb" % BUILD_ID, "collider": "mesh", "sound": "crowd", "scale": 2.0},
                    "rings": [{"half": [8.0, 8.0], "spacing": 7.5, "part": timber_house(r)}],
                    "props": [{"url": BENCH, "pos": [4, 4]}, {"url": BENCH, "pos": [-4, -4]},
                              {"url": STREETLIGHT, "pos": [6, -6]}],
                    "populate": [{"set": TOWN_CROWD, "count": 3, "vary": True,
                                  "behaviour": "wander", "rig": "kaykit", "radius": 7.0, "speed": 1.1}]}
        else:
            ground = "dirt" if gx == 0 else r.choice(["sandstone", "grass", "dirt"])
            cell = {"cell": [gx, gz], "ground": ground}
            structs = []
            spots = [(-6, -6), (6, -6), (-6, 6), (6, 6), (0, 6)]
            r.shuffle(spots)
            for i in range(r.choice([2, 3])):
                h = timber_house(r)["structure"]
                h["pos"] = list(spots[i])
                structs.append(h)
            cell["structures"] = structs
            cell["scatter"] = [{"url": r.choice(TREES), "count": r.randint(4, 8)},
                               {"url": r.choice(BUSHES), "count": r.randint(4, 7)}]
            if r.random() < 0.5:
                cell["populate"] = [{"set": TOWN_CROWD, "count": 2, "vary": True,
                                     "behaviour": "wander", "rig": "kaykit", "radius": 6.0, "speed": 1.1}]
        cells.append(cell)

find_cell(0, 12)["npc"] = {"id": "bram", "name": "Old Bram", "pos": [7, 0], "model": "characters/kk_Rogue_Hooded.glb",
    "persona": "You are Old Bram, a warm elderly townsman in the cozy old timber quarter, proud of the plaza fountain and the tree-lined boulevard. A little nostalgic. Answer in ONE short sentence.",
    "lines": ["Bram: You made it to the old town - welcome, traveler.",
              "Bram: This fountain's older than the whole city down the road."]}

world = {
    "mode": "chunk",
    "title": "Overland",
    "grid": {"cell_size": 20},
    "start_cell": [0, 0],
    "goal": {"type": "reach_cell", "target": [0, 12]},
    "default_npc_model": "characters/kk_Rogue.glb",
    "terrain": {"amplitude": 7.0, "frequency": 0.005, "seed": 91, "octaves": 3, "material": "grass", "resolution": 10},
    "sky": {"loop": True, "cycle": [
        {"time": "day", "weather": "clear", "seconds": 75},
        {"time": "sunset", "weather": "cloudy", "seconds": 28},
        {"time": "night", "weather": "clear", "seconds": 50},
        {"time": "sunrise", "weather": "rain", "seconds": 28},
    ]},
    "cells": cells,
}

with open("world.json", "w") as f:
    json.dump(world, f, indent=1)
print("wrote world.json:", len(cells), "cells")
