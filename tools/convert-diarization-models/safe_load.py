# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Restricted loader for pyannote checkpoints (torch zip + pickle).
Only an allowlist of globals is resolvable; pyannote.audio.* classes become inert stubs,
so no pyannote code (and no arbitrary code) ever runs. Also forbids REDUCE on anything unexpected
by construction: unknown globals raise."""
import pickle, types, collections, torch, torch._utils, torch.torch_version

class _Stub:
    def __init__(self, *a, **k): pass
    def __setstate__(self, s): self.state = s

_ALLOW = {
    ("collections", "OrderedDict"): collections.OrderedDict,
    ("torch._utils", "_rebuild_tensor_v2"): torch._utils._rebuild_tensor_v2,
    ("torch", "FloatStorage"): torch.FloatStorage,
    ("torch", "LongStorage"): torch.LongStorage,
    ("torch", "HalfStorage"): torch.HalfStorage,
    ("torch.torch_version", "TorchVersion"): torch.torch_version.TorchVersion,
}

class _Unpickler(pickle.Unpickler):
    def find_class(self, module, name):
        if (module, name) in _ALLOW: return _ALLOW[(module, name)]
        if module.startswith("pyannote.audio."): return type(name, (_Stub,), {})
        raise pickle.UnpicklingError(f"blocked global {module}.{name}")

safe_pickle = types.ModuleType("safe_pickle")
safe_pickle.Unpickler = _Unpickler
safe_pickle.load = lambda f, **k: _Unpickler(f, **k).load()
safe_pickle.UnpicklingError = pickle.UnpicklingError
safe_pickle.__name__ = "safe_pickle"

def load_checkpoint(path):
    return torch.load(path, map_location="cpu", pickle_module=safe_pickle, weights_only=False)
