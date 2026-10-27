#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Makes the parity goldens of the search model with Hugging Face's reference stack (sentence-transformers, fp32, no Vauta code).

    python3 -m venv venv && venv/bin/pip install -r tools/search-model/requirements-goldens.txt
    venv/bin/python tools/search-model/make-goldens.py <model-dir> > goldens.base64

<model-dir> is a checkout of google/embeddinggemma-2 at revision 914f7f89142e33e77833254d9c9b90c3cef7303b (the same files Vauta
pins; verify them with tools/search-model/make-tensor-table.py first). Run it by hand on a Mac you control: tests and agents never
download the model. The output is the base64 for `SearchModelGoldens.vectorsBase64` (Sources/VautaCore/SearchModel/
SearchModelGoldens.swift): the document vectors of its sentences, text tower only, official "document" prompt, 512-token limit,
fp32, the first 256 dimensions renormalised (Matryoshka), little-endian float32.
"""
import base64, re, sys
import numpy as np, torch
from sentence_transformers import SentenceTransformer

SWIFT = "Sources/VautaCore/SearchModel/SearchModelGoldens.swift"


def sentences():
    source = open(SWIFT, encoding="utf-8").read()
    block = re.search(r"static let strings: \[String\] = \[(.*?)\n    \]", source, re.S).group(1)
    return re.findall(r'^\s*"(.*)",\s*$', block, re.M)


def main(model_dir):
    model = SentenceTransformer(model_dir, device="cpu", trust_remote_code=False,
                                config_kwargs={"vision_config": None, "audio_config": None},
                                model_kwargs={"torch_dtype": torch.float32})
    model.max_seq_length = 512
    texts = sentences()
    full = model.encode(texts, prompt_name="document", batch_size=1, normalize_embeddings=True, convert_to_numpy=True)
    cut = full[:, :256]
    cut = cut / np.linalg.norm(cut, axis=1, keepdims=True)
    print(base64.b64encode(cut.astype("<f4").tobytes()).decode())


if __name__ == "__main__":
    main(sys.argv[1])
