One-off tools that are not part of the engine CLI. Run them from `engine/`.

| Script | What it does |
| --- | --- |
| `install_su2.sh` | Builds SU2 8.5 into `build/su2` (and installs Open MPI with Homebrew if missing). The Wing Lab's *Install SU2* runs it. |
| `fetch_airfoils.py` | Downloads the UIUC airfoil database and builds the library index. The Wing Lab's *Download the Library* does the same. |
| `make_tracks.py` | Turns the fssim cone layouts into the centrelines in `data/tracks`. |
| `make_sample_cad.py` | Builds the synthetic CAD assembly in `samples/`. |
