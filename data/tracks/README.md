# Lap Sim tracks

Closed centrelines in metres (x, y), one point per row, read like an
imported CSV track (spline-smoothed, curvature from the spline).

| File | Track | Length | Source |
| --- | --- | --- | --- |
| fsg_2019.csv | Formula Student Germany, Hockenheim: trackdrive layout | 309 m | AMZ fssim, FSG.yaml (MIT) |
| fsi_2019.csv | Formula Student Italy, Varano: trackdrive layout | 218 m | AMZ fssim, FSI.yaml (MIT) |

The centreline is the midpoint between each left cone and the nearest right
cone, made by engine/scripts/make_tracks.py. These are the driverless
trackdrive layouts the simulator ships with: real event layouts, shorter
than an endurance lap and laid out with cones, so treat lap times as
relative (car A against car B), not as event predictions.
