"""Training for the VisionAX region-role classifier.

The runtime contract lives in `preprocess.py`; it is the twin of Frigate's
`Sources/CVisionAX/ClassifierPreprocess.cpp` (the runtime lives there) and the two must
not drift.
"""

__all__ = ["preprocess", "roles"]
