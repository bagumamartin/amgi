"""
Precompute icon-tag embeddings with multilingual-e5-small.
Run ONCE, locally, at dev time. Output ships as a bundled SPM resource —
never regenerated on-device.

The tag manifest is icon_tags_full.py: all 1,512 Phosphor icons with the
official @phosphor-icons/core search tags. Regenerate it (re-run the
extraction against @phosphor-icons/core) if Phosphor is updated.

Setup (run locally, not in a network-restricted sandbox):
    pip install sentence-transformers

Usage:
    python precompute_embeddings.py
    -> writes IconEmbeddings.json into this directory
"""

import json
from sentence_transformers import SentenceTransformer
from icon_tags_full import ICON_TAGS

MODEL_NAME = "intfloat/multilingual-e5-small"
OUTPUT_PATH = "IconEmbeddings.json"


def main() -> None:
    print(f"Loading {MODEL_NAME} ...")
    model = SentenceTransformer(MODEL_NAME)

    icon_names = list(ICON_TAGS.keys())
    # e5 convention: tag/document side gets the "passage: " prefix.
    passages = [f"passage: {ICON_TAGS[name]}" for name in icon_names]

    print(f"Embedding {len(passages)} icon tag strings ...")
    vectors = model.encode(
        passages,
        normalize_embeddings=True,  # so runtime cosine similarity is a plain dot product
        show_progress_bar=True,
    )

    output = {
        icon_names[i]: [round(float(x), 6) for x in vectors[i]]
        for i in range(len(icon_names))
    }

    with open(OUTPUT_PATH, "w") as f:
        json.dump(output, f)

    print(f"Wrote {len(output)} vectors ({len(vectors[0])} dims each) to {OUTPUT_PATH}")
    print("Copy this file into your SwiftUI package's Resources/ directory.")


if __name__ == "__main__":
    main()
