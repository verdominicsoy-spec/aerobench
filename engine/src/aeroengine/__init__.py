"""AeroBench compute engine."""

import os as _os

# The engine's own linear algebra is small (panel matrices of a few hundred
# rows): one BLAS thread is fastest, and with several, every estimate fought
# a running SU2 for the cores (546 ms an estimate against 31 ms with one).
# SU2 runs as its own process with its own thread settings. Set before numpy
# loads; an explicit setting in the environment wins.
for _name in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    _os.environ.setdefault(_name, "1")

__version__ = "0.1.0"
