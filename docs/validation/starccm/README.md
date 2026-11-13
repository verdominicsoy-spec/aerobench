# STAR-CCM+ against AeroBench

`compare.py` puts a STAR-CCM+ run of a wing beside AeroBench's RANS of the same wing: where each says the flow is reversed, element by element and surface by surface, the forces, and (with `--plot`) Cp and Cf overlaid.

## What to export from STAR-CCM+

For each wing element, on a section at mid-span (Derived Parts > Section > Plane, normal to the span, then the line where it cuts that element's boundary):

1. Tools > Tables > new XYZ Internal Table on that line.
2. Scalars: Pressure Coefficient (reference density, velocity and pressure set to the freestream), Wall Shear Stress, component i (along the car, x).
3. Export as CSV: one file per element, main first. The table carries Position[X] and Position[Z] (Z up).

Also note: the front-wing downforce and drag (N) and the reference area used, the span, the endplate height, the ride height (lowest point of the wing to the ground) and the car's pitch.

## Run

```bash
engine/.venv/bin/python docs/validation/starccm/compare.py --aerobench <job folder>/result.json \
    --rho 1.184 --speed 20 --star main.csv flap1.csv flap2.csv flap3.csv --plot compare.png
```

Run AeroBench at STAR's conditions first: ride height under Flow, span and endplate under Use in the Lap Sim, *As on the car (3D)* on. A 2D section at its full angle will not match a wing on a car (frontwing1/README.md).

`--self-test` checks the reader and the reversed-flow runs on a made-up section.
