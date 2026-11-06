# Glossary

The words AeroBench uses, one per thing. Where a value is pasted into STAR-CCM+, the term is STAR's field name.

| Term | Means | Not |
| --- | --- | --- |
| Number of Prism Layers | STAR's prism control field: how many layers | layer count, n layers |
| Prism Layer Total Thickness | STAR's field: the whole stack, wall to outer layer | total height, stack thickness |
| Prism Layer Near Wall Thickness | STAR's field: the first cell's height | first cell, h1, wall spacing |
| Target y+ | The y+ you size the near wall cell for | desired y+ |
| Achieved y+ | The y+ the near wall thickness gives back | |
| Stretching | Growth ratio from one layer to the next | growth rate, expansion ratio |
| Reference length | The length the Reynolds number uses, normally the main element's chord | characteristic length |
| Nearest gap to another wall | Smallest distance from this surface to another one that grows prisms | clearance |
| Wall functions | y+ 30 to 100, the first cell in the log layer | |
| Resolved | y+ about 1, the first cell in the viscous sublayer | low-Re, wall-resolved |
| Velocity | Free-stream speed in m/s | speed, U |
| ClA, CdA | Lift and drag coefficient times area, m² | |
| Cl, Cd, L/D | Section (2D) coefficients | |
| Element | One airfoil in the wing (main, flap 1, flap 2) | foil, section (a section is the airfoil shape) |
| Section | An airfoil shape from the library (S1223) | profile |
| Gap, overlap | Between an element's leading edge and the trailing edge of the one in front | slot |
| Panel solver | The inviscid estimate that runs as you edit | live estimate (the readout that shows it) |
| RANS | The SU2 RANS CFD run | CFD, SU2 run |
| Job | One engine run, listed in Jobs | task, run |
| Project | A folder with project.json, one subfolder per tool, and jobs/ | |
