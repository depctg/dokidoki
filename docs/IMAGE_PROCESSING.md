# Image processing

MangaCore owns analysis, display planning and composition. The reader feeds visible/prefetched images into the existing `identity → marginAlign → spreadDetect → layout` pipeline. Originals and source-based progress stay unchanged; there is no extra fetch or full-chapter image scan.

## Rejoining a split spread

`ImageProcessing.analyze` samples at most 1024 × 256 RGBA pixels (1 MiB). It measures nearly white outer columns, stopping at artwork or 10% of the image width. The horizontal white threshold permits faint JPEG ringing. General margin trimming retains a safety border; separate seam bounds record the measured cut without that border.

`spreadDetect` compares only consecutive source pages, in the selected reading direction. Analysis rejects a boundary if its mean squared color difference from a column about 3% inward exceeds 0.04; repeated black panel frames changing abruptly to unrelated interiors cannot supply seam evidence. `SplitPageJoin` then requires portrait halves, heights within 8%, and non-flat RGB profiles at their meeting artwork edges. Sixty-four samples per edge must have spatial variance above 0.012 and at least six visible transitions. Mean squared RGB difference between the pages must be below 0.0025. These conservative thresholds are application heuristics, not a trained classifier or a claim of universal accuracy.

A match becomes one `DisplayPage` with two regions in visual left-to-right order. Only the touching white margins are removed. Outer borders follow the existing margin preference, and both regions use a shared vertical extent to preserve alignment. Core Graphics crops/composes the regions at equal display height without a gap. This works in paged and scroll modes, including narrow windows; ordinary facing-page layout remains separate. The existing **Detect spreads** toggle disables automatic joining, and **Keep original** on either source prevents it. Explicit **Pair with next** still works without automatic evidence, retaining its original crops when no match is found.

Only left/right cuts with matching artwork are handled. Top/bottom slices, rotated/skewed scans, black binding margins, large missing/overlapping regions, and art reconstruction remain outside this processor. Sparse or heavily altered seams can be missed; similar repeated artwork can still match. Uncertain cases remain separate rather than deleting content. Old analysis without seam evidence cannot automatically join.

## External basis

The boundary-color comparison adapts the dissimilarity measure in section 3.1 of [Cho, Avidan and Freeman, “A probabilistic image jigsaw puzzle solver,” CVPR 2010](https://people.csail.mit.edu/taegsang/JigsawSolver.pdf). Their method compares squared color differences at abutting boundaries. This implementation uses normalized RGB samples rather than their normalized Lab space, since adjacent manga pages already have a known order; it does not implement their global puzzle solver. Border limits and ambiguity checks are application-specific additions. Implementation uses native Core Graphics/Image I/O and adds no dependencies.

## Verification fixture

The bundled reading room's **Aster House → Across the valley** is original continuous geometric artwork cut into right/left halves, with unequal white padding at the cut. Regenerate it with `swift scripts/generate-split-fixture.swift`. The JSON fixture supplies normal chapter/image references; it uses the same core loading and reader pipeline as any installed site rule.

Core tests cover padded/unpadded cuts, reading modes/directions, JPEG compression, blank/color/panel borders, unrelated images, scan-limit rejection, old analysis, source-position mapping and actual composition. The existing reader UI journey checks that the joined image appears immediately after opening (without a settings change), works in both modes and separates when detection is disabled.
