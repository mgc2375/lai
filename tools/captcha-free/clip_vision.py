"""Tiny local zero-shot image classifier (MobileCLIP-S0, ONNX).

Just the CLIP image + text encoders — no LLM, no API, no key. Given an image
and candidate labels it returns a similarity score per label, which is enough
to pick "which tiles contain an X" for an image-grid captcha, or to answer
"does this image contain X" for the agent. ~55 MB of quantized ONNX.

Deps: onnxruntime, pillow, numpy, tokenizers. No torch, no transformers.
"""
import os
import urllib.request

import numpy as np

_REPO = "https://huggingface.co/Xenova/mobileclip_s0/resolve/main"
# fp16 vision + int8 text: ~66 MB and accurate. (int8 vision is too lossy.)
_FILES = {
    "vision": "onnx/vision_model_fp16.onnx",
    "text": "onnx/text_model_quantized.onnx",
    "tokenizer.json": "tokenizer.json",
}
_SIZE = 256  # from preprocessor_config.json (resize shortest edge + center crop, no mean/std)
_CTX = 77    # CLIP text context length

_state = {}


def model_dir() -> str:
    return os.environ.get("LAI_CLIP_DIR") or os.path.join(os.path.dirname(__file__), "clip")


def ensure_model() -> str:
    """Download the ~55 MB model into model_dir() once; return the dir."""
    d = model_dir()
    os.makedirs(os.path.join(d, "onnx"), exist_ok=True)
    for _, rel in _FILES.items():
        dst = os.path.join(d, rel)
        if not os.path.exists(dst) or os.path.getsize(dst) == 0:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            urllib.request.urlretrieve(f"{_REPO}/{rel}", dst)
    return d


def _load():
    if _state:
        return _state
    import onnxruntime as ort
    from tokenizers import Tokenizer

    d = ensure_model()
    so = ort.SessionOptions()
    so.log_severity_level = 3
    _state["vision"] = ort.InferenceSession(os.path.join(d, _FILES["vision"]), so, providers=["CPUExecutionProvider"])
    _state["text"] = ort.InferenceSession(os.path.join(d, _FILES["text"]), so, providers=["CPUExecutionProvider"])
    tok = Tokenizer.from_file(os.path.join(d, "tokenizer.json"))
    tok.enable_truncation(max_length=_CTX)
    tok.enable_padding(length=_CTX, pad_id=0)
    _state["tok"] = tok
    return _state


def _preprocess(img) -> np.ndarray:
    from PIL import Image

    img = img.convert("RGB")
    w, h = img.size
    scale = _SIZE / min(w, h)
    img = img.resize((round(w * scale), round(h * scale)), Image.BILINEAR)
    w, h = img.size
    left, top = (w - _SIZE) // 2, (h - _SIZE) // 2
    img = img.crop((left, top, left + _SIZE, top + _SIZE))
    arr = np.asarray(img, dtype=np.float32) / 255.0      # [0,1], no mean/std for MobileCLIP
    return np.transpose(arr, (2, 0, 1))[None, ...]        # 1x3xHxW


def _run(sess, feed_main, name_main):
    feeds = {}
    for inp in sess.get_inputs():
        if inp.name in ("pixel_values", "input_ids") or inp.name == name_main:
            feeds[inp.name] = feed_main
        elif inp.name == "attention_mask":
            feeds[inp.name] = (feed_main != 0).astype(np.int64)
    out = sess.run(None, feeds)[0]
    return out.astype(np.float32)


def _norm(x):
    return x / (np.linalg.norm(x, axis=-1, keepdims=True) + 1e-8)


def image_embed(img) -> np.ndarray:
    s = _load()
    return _norm(_run(s["vision"], _preprocess(img), "pixel_values"))[0]


def text_embed(labels) -> np.ndarray:
    s = _load()
    ids = np.array([e.ids for e in s["tok"].encode_batch(list(labels))], dtype=np.int64)
    return _norm(_run(s["text"], ids, "input_ids"))


def match(img, labels):
    """Return a list of (label, score 0..1) sorted high-to-low; softmax over labels."""
    iv = image_embed(img)
    tv = text_embed(labels)
    sims = tv @ iv                       # cosine similarity per label
    logits = sims * 100.0                # CLIP logit scale
    e = np.exp(logits - logits.max())
    probs = e / e.sum()
    return sorted(zip(list(labels), probs.tolist()), key=lambda x: -x[1])
