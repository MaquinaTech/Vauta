# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
import json,sys
d=json.load(open(sys.argv[1])); lo=int(sys.argv[2]) if len(sys.argv)>2 else 0; hi=int(sys.argv[3]) if len(sys.argv)>3 else 10**9
for p in d["passages"]:
    if lo<=p["id"]<=hi: print(p["id"],int(p["start"]//60),p["speaker"].split()[1][:2] if p["speaker"].startswith("Speaker ") and "(" in p["speaker"] else p["speaker"],p["text"])
