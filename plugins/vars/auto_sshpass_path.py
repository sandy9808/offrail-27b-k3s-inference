from __future__ import annotations

import os
from ansible.plugins.vars import BaseVarsPlugin

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LOCAL_BIN = os.path.join(PROJECT_ROOT, "bin")
if os.path.isdir(LOCAL_BIN) and LOCAL_BIN not in os.environ.get("PATH", "").split(os.pathsep):
    os.environ["PATH"] = LOCAL_BIN + os.pathsep + os.environ.get("PATH", "")


class VarsModule(BaseVarsPlugin):
    def get_vars(self, loader, path, entities, cache=True):
        super().get_vars(loader, path, entities)
        return {}

