# Bundled models

`region-classifier.json` (the spec), `region-classifier.backbone.onnx` and
`region-classifier.head.onnx` land here from
`uv run vxtrain export --out ../Sources/VisionAX/Resources/Models`.

The `.onnx` files are tracked with git-lfs. After a fresh clone run `git lfs pull`;
without it `RegionClassifier.bundled()` throws `.modelIsLFSPointer` rather than
handing ONNX Runtime a pointer file.

This directory ships as a SwiftPM resource bundle, so a consumer (Mary) gets the
model by depending on the `VisionAX` library — but an app bundle must copy
`VisionAX_VisionAX.bundle` into `Contents/Resources` for `Bundle.module` to find it.
